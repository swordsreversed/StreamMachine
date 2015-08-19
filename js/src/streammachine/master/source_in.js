var IcecastSource, SourceIn, express, net, _u,
  __bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; },
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_u = require("underscore");

net = require("net");

express = require("express");

IcecastSource = require("../sources/icecast");

module.exports = SourceIn = (function(_super) {
  __extends(SourceIn, _super);

  function SourceIn(opts) {
    this._trySource = __bind(this._trySource, this);
    this._connection = __bind(this._connection, this);
    this.core = opts.core;
    this.log = this.core.log.child({
      mode: "sourcein"
    });
    this.port = opts.port;
    this.behind_proxy = opts.behind_proxy;
    this.server = net.createServer((function(_this) {
      return function(c) {
        return _this._connection(c);
      };
    })(this));
  }

  SourceIn.prototype.listen = function(spec) {
    if (spec == null) {
      spec = this.port;
    }
    return this.server.listen(spec);
  };

  SourceIn.prototype._connection = function(sock) {
    var parser, readerF, timer;
    this.log.debug("Incoming source attempt.");
    sock.on("error", (function(_this) {
      return function(err) {
        return _this.log.debug("Source socket errored with " + err);
      };
    })(this));
    timer = setTimeout((function(_this) {
      return function() {
        _this.log.debug("Incoming source connection failed to validate before timeout.");
        sock.write("HTTP/1.0 400 Bad Request\r\n");
        return sock.end("Unable to validate source connection.\r\n");
      };
    })(this), 2000);
    parser = new SourceIn.IcyParser(SourceIn.IcyParser.REQUEST);
    readerF = (function(_this) {
      return function() {
        var d, _results;
        _results = [];
        while (d = sock.read()) {
          _results.push(parser.execute(d));
        }
        return _results;
      };
    })(this);
    sock.on("readable", readerF);
    parser.once("invalid", (function(_this) {
      return function() {
        sock.removeListener("readable", readerF);
        return sock.end("HTTP/1.0 400 Bad Request\n\n");
      };
    })(this));
    return parser.once("headersComplete", (function(_this) {
      return function(headers) {
        clearTimeout(timer);
        if (parser.info.protocol === "ICE" || parser.info.method === "SOURCE") {
          _this.log.debug("ICY SOURCE attempt.", {
            url: parser.info.url
          });
          _this._trySource(sock, parser.info);
          return sock.removeListener("readable", readerF);
        }
      };
    })(this));
  };

  SourceIn.prototype._trySource = function(sock, info) {
    var m, mount, sg, stream, _authFunc;
    _authFunc = (function(_this) {
      return function(stream) {
        var source, source_ip;
        _this.log.debug("Trying to authenticate ICY source for " + stream.key);
        if (info.headers.authorization && _this._authorize(stream.opts.source_password, info.headers.authorization)) {
          sock.write("HTTP/1.0 200 OK\n\n");
          _this.log.debug("ICY source authenticated for " + stream.key + ".");
          source_ip = sock.remoteAddress;
          if (_this.behind_proxy && info.headers['x-forwarded-for']) {
            source_ip = info.headers['x-forwarded-for'];
          }
          source = new IcecastSource({
            format: stream.opts.format,
            sock: sock,
            headers: info.headers,
            logger: stream.log,
            source_ip: source_ip
          });
          return stream.addSource(source);
        } else {
          _this.log.debug("ICY source failed to authenticate for " + stream.key + ".");
          sock.write("HTTP/1.0 401 Unauthorized\r\n");
          return sock.end("Invalid source or password.\r\n");
        }
      };
    })(this);
    if (Object.keys(this.core.source_mounts).length > 0 && (m = RegExp("^/(" + (Object.keys(this.core.source_mounts).join("|")) + ")").exec(info.url))) {
      mount = this.core.source_mounts[m[1]];
      return _authFunc(mount);
    } else if (Object.keys(this.core.stream_groups).length > 0 && (m = RegExp("^/(" + (Object.keys(this.core.stream_groups).join("|")) + ")").exec(info.url))) {
      sg = this.core.stream_groups[m[1]];
      return _authFunc(sg._stream);
    } else if (m = RegExp("^/(" + (Object.keys(this.core.streams).join("|")) + ")").exec(info.url)) {
      stream = this.core.streams[m[1]];
      return _authFunc(stream);
    } else {
      this.log.debug("ICY source attempted to connect to bad URL.", {
        url: info.url
      });
      sock.write("HTTP/1.0 401 Unauthorized\r\n");
      return sock.end("Invalid source or password.\r\n");
    }
  };

  SourceIn.prototype._tmp = function() {
    if (/^\/admin\/metadata/.match(req.url)) {
      res.writeHead(200, headers);
      return res.end("OK");
    } else {
      res.writeHead(400, headers);
      return res.end("Invalid method " + res.method + ".");
    }
  };

  SourceIn.prototype._authorize = function(stream_passwd, header) {
    var pass, type, user, value, _ref, _ref1;
    _ref = header.split(" "), type = _ref[0], value = _ref[1];
    if (type.toLowerCase() === "basic") {
      value = new Buffer(value, 'base64').toString('ascii');
      _ref1 = value.split(":"), user = _ref1[0], pass = _ref1[1];
      if (pass === stream_passwd) {
        return true;
      } else {
        return false;
      }
    } else {
      return false;
    }
  };

  SourceIn.IcyParser = (function(_super1) {
    __extends(IcyParser, _super1);

    function IcyParser(type) {
      this["INIT_" + type]();
      this.offset = 0;
    }

    IcyParser.REQUEST = "REQUEST";

    IcyParser.RESPONSE = "RESPONSE";

    IcyParser.prototype.reinitialize = IcyParser;

    IcyParser.prototype.execute = function(chunk) {
      this.chunk = chunk;
      this.offset = 0;
      this.end = this.chunk.length;
      while (this.offset < this.end) {
        this[this.state]();
        this.offset++;
      }
      return true;
    };

    IcyParser.prototype.INIT_REQUEST = function() {
      this.state = "REQUEST_LINE";
      this.lineState = "DATA";
      return this.info = {
        headers: {}
      };
    };

    IcyParser.prototype.consumeLine = function() {
      var byte, line;
      if (this.captureStart == null) {
        this.captureStart = this.offset;
      }
      byte = this.chunk[this.offset];
      if (byte === 0x0d && this.lineState === "DATA") {
        this.captureEnd = this.offset;
        this.lineState = "ENDING";
        return;
      }
      if (this.lineState === "ENDING") {
        this.lineState = "DATA";
        if (byte !== 0x0a) {
          return;
        }
        line = this.chunk.toString("ascii", this.captureStart, this.captureEnd);
        this.captureStart = void 0;
        this.captureEnd = void 0;
        return line;
      }
    };

    IcyParser.prototype.requestExp = /^([A-Z]+) (.*) (ICE|HTTP)\/(1).(0|1)$/;

    IcyParser.prototype.REQUEST_LINE = function() {
      var line, match, _ref;
      line = this.consumeLine();
      if (line == null) {
        return;
      }
      match = this.requestExp.exec(line);
      if (match) {
        _ref = match.slice(1, 6), this.info.method = _ref[0], this.info.url = _ref[1], this.info.protocol = _ref[2], this.info.versionMajor = _ref[3], this.info.versionMinor = _ref[4];
      } else {
        this.emit("invalid");
      }
      this.info.request_offset = this.offset;
      this.info.request_line = line;
      return this.state = "HEADER";
    };

    IcyParser.prototype.headerExp = /^([^:]+): *(.*)$/;

    IcyParser.prototype.HEADER = function() {
      var line, match;
      line = this.consumeLine();
      if (line == null) {
        return;
      }
      if (line) {
        match = this.headerExp.exec(line);
        return this.info.headers[match[1].toLowerCase()] = match[2];
      } else {
        return this.emit("headersComplete", this.info.headers);
      }
    };

    return IcyParser;

  })(require("events").EventEmitter);

  return SourceIn;

})(require("events").EventEmitter);

//# sourceMappingURL=source_in.js.map
