import handy_httpd;
import handy_httpd.handlers.path_delegating_handler;
import slf4d;
import d_properties;
import d2sqlite3;

import std.file;
import std.conv;
import std.json;
import std.datetime;

void main() {
	ServerConfig config = ServerConfig.defaultValues();
	if (exists("application.properties")) {
		Properties props = Properties("application.properties");
		if (props.has("hostname")) {
			config.hostname = props.get("hostname");
		}
		if (props.has("port")) {
			config.port = props.get("port").to!ushort;
		}
	}
	initDb();
	HttpServer server = new HttpServer((ref HttpRequestContext ctx) {
		ctx.response.addHeader("Access-Control-Allow-Origin", "*");
		ctx.response.addHeader("Access-Control-Allow-Headers", "*");
		if (ctx.request.method == Method.GET) {
			handleLogbookRequest(ctx);
		} else if (ctx.request.method == Method.POST) {
			handleVisitorLog(ctx);
		} else if (ctx.request.method == Method.OPTIONS) {
			ctx.response.setStatus(HttpStatus.OK);
		} else {
			ctx.response.setStatus(HttpStatus.METHOD_NOT_ALLOWED);
		}
	}, config);
	server.start();
}

void handleVisitorLog(ref HttpRequestContext ctx) {
	infoF!"Got visitor log from %s"(ctx.request.remoteAddress);
	JSONValue logBody = ctx.request.readBodyAsJson();
	string name = logBody.object["name"].str;
	string message = logBody.object["message"].str;
	string remoteAddress = "UNKNOWN";
	if (ctx.request.remoteAddress !is null) {
		remoteAddress = ctx.request.remoteAddress.toString();
	}
	insertLogEntry(remoteAddress, name, message);
}

void handleLogbookRequest(ref HttpRequestContext ctx) {
	LogEntry[] entries = getRecentLogEntries();
	JSONValue entriesJson = JSONValue(JSONValue[].init);
	foreach (LogEntry entry; entries) {
		entriesJson.array ~= entry.toJson();
	}
	ctx.response.writeBodyString(entriesJson.toString(), "application/json");
}



struct LogEntry {
	ulong id;
	SysTime createdAt;
	string remoteAddress;
	string name;
	string message;

	JSONValue toJson() const {
		JSONValue obj = JSONValue(string[string].init);
		obj["id"] = JSONValue(id);
		obj["createdAt"] = JSONValue(createdAt.toISOString());
		obj["remoteAddress"] = JSONValue(remoteAddress);
		obj["name"] = JSONValue(name);
		obj["message"] = JSONValue(message);
		return obj;
	}
}

void initDb() {
	Database db = Database("logbook.sqlite");
	db.run(q"SQL
CREATE TABLE IF NOT EXISTS log_entry (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
	remote_address TEXT NOT NULL,
	name TEXT NOT NULL,
	message TEXT NOT NULL
);
SQL");
	db.close();
	info("Initialized database.");
}

void insertLogEntry(string remoteAddress, string name, string message) {
	Database db = Database("logbook.sqlite");
	Statement stmt = db.prepare(q"SQL
INSERT INTO log_entry (remote_address, name, message)
VALUES (:addr, :name, :msg);
SQL");
	stmt.bind(1, remoteAddress);
	stmt.bind(2, name);
	stmt.bind(3, message);
	stmt.execute();
	stmt.finalize();
	db.close();
	infoF!"Added log entry for %s @ %s"(name, remoteAddress);
}

LogEntry[] getRecentLogEntries() {
	Database db = Database("logbook.sqlite");
	ResultRange results = db.execute("SELECT * FROM log_entry ORDER BY created_at DESC LIMIT 5");
	LogEntry[] entries;
	foreach (Row row; results) {
		LogEntry entry;
		entry.id = row.peek!ulong(0);
		string createdAtStr = row.peek!string(1);
		string isoCreatedAt = createdAtStr[0 .. 4] ~ createdAtStr[5 .. 7] ~ createdAtStr[8 .. 10] ~ 'T' ~
			createdAtStr[11 .. 13] ~ createdAtStr[14 .. 16] ~ createdAtStr[17 .. $];
		entry.createdAt = SysTime.fromISOString(isoCreatedAt);
		entry.remoteAddress = row.peek!string(2);
		entry.name = row.peek!string(3);
		entry.message = row.peek!string(4);
		entries ~= entry;
	}
	return entries;
}
