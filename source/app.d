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
		if (props.has("workers")) {
			config.workerPoolSize = props.get("workers").to!size_t;
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
	JSONValue logBody = ctx.request.readBodyAsJson();
	string name = logBody.object["name"].str;
	if (name.length > 32) {
		ctx.response.setStatus(HttpStatus.BAD_REQUEST);
		ctx.response.writeBodyString("Name is too long.");
		return;
	}
	string message = logBody.object["message"].str;
	if (message.length > 255) {
		ctx.response.setStatus(HttpStatus.BAD_REQUEST);
		ctx.response.writeBodyString("Message is too long.");
		return;
	}
	if (!ctx.request.hasHeader("X-Forwarded-For")) {
		ctx.response.setStatus(HttpStatus.FORBIDDEN);
		ctx.response.writeBodyString("Missing remote IP");
		return;
	}
	string remoteAddress = ctx.request.getHeader("X-Forwarded-For");

	// If the user has sent another log within the last minute, block this one.
	LogEntry[] recentLogsByThisAddress = getRecentLogEntriesByRemoteAddress(remoteAddress);
	SysTime now = Clock.currTime();
	if (recentLogsByThisAddress.length > 0 && now - recentLogsByThisAddress[0].createdAt < minutes(1)) {
		ctx.response.setStatus(HttpStatus.TOO_MANY_REQUESTS);
		return;
	}

	insertLogEntry(remoteAddress, name, message);
}

void handleLogbookRequest(ref HttpRequestContext ctx) {
	uint limit = ctx.request.getParamAs!uint("limit", 5);
	if (limit > 100) {
		ctx.response.setStatus(HttpStatus.BAD_REQUEST);
		ctx.response.writeBodyString("Limit is too large.");
		return;
	}
	uint offset = ctx.request.getParamAs!uint("offset", 0);
	LogEntry[] entries = getRecentLogEntries(limit, offset);
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
		obj["createdAt"] = JSONValue(createdAt.toISOExtString());
		obj["remoteAddress"] = JSONValue(remoteAddress);
		obj["name"] = JSONValue(name);
		obj["message"] = JSONValue(message);
		return obj;
	}

	static LogEntry fromDbRow(ref Row row) {
		LogEntry entry;
		entry.id = row.peek!ulong(0);
		string createdAtStr = row.peek!string(1);
		string isoCreatedAt = createdAtStr[0 .. 4] ~ createdAtStr[5 .. 7] ~ createdAtStr[8 .. 10] ~ 'T' ~
			createdAtStr[11 .. 13] ~ createdAtStr[14 .. 16] ~ createdAtStr[17 .. $];
		entry.createdAt = SysTime.fromISOString(isoCreatedAt);
		entry.remoteAddress = row.peek!string(2);
		entry.name = row.peek!string(3);
		entry.message = row.peek!string(4);
		return entry;
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

LogEntry[] findAllByQuery(string query) {
	import std.array : Appender, appender;
	Database db = Database("logbook.sqlite");
	ResultRange results = db.execute(query);
	Appender!(LogEntry[]) app = appender!(LogEntry[])();
	foreach (Row row; results) {
		app ~= LogEntry.fromDbRow(row);
	}
	return app.data();
}

LogEntry[] getRecentLogEntries(uint limit, uint offset) {
	import std.format;
	string query = format!"SELECT * FROM log_entry ORDER BY created_at DESC LIMIT %d OFFSET %d"(limit, offset);
	return findAllByQuery(query);
}

LogEntry[] getRecentLogEntriesByRemoteAddress(string remoteAddress) {
	import std.array : Appender, appender;
	Database db = Database("logbook.sqlite");
	Statement stmt = db.prepare("SELECT * FROM log_entry WHERE remote_address = :addr ORDER BY created_at DESC LIMIT 10");
	stmt.bind(1, remoteAddress);
	ResultRange results = stmt.execute();
	Appender!(LogEntry[]) app = appender!(LogEntry[])();
	foreach (Row row; results) {
		app ~= LogEntry.fromDbRow(row);
	}
	return app.data();
}
