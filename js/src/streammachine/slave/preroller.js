var Preroller, http, url, _u;

_u = require("underscore");

http = require("http");

url = require("url");

module.exports = Preroller = (function() {
  function Preroller(stream, key, uri, cb) {
    this.stream = stream;
    this.key = key;
    this._counter = 1;
    this.uri = url.parse(uri);
    if (this.uri.protocol !== "http:") {
      if (typeof cb === "function") {
        cb("Preroller only supports HTTP connections.");
      }
      return false;
    }
    this.stream.log.debug("Preroller calling getStreamKey");
    this.stream.getStreamKey((function(_this) {
      return function(streamKey) {
        _this.streamKey = streamKey;
        _this.uri.path = [_this.uri.path, _this.key, _this.streamKey].join("/").replace(/\/\//g, "/");
        return _this.stream.log.debug("Preroller: Stream key is " + _this.streamKey + ". URI is " + _this._uri);
      };
    })(this));
    if (typeof cb === "function") {
      cb(null, this);
    }
  }

  Preroller.prototype.pump = function(socket, writer, cb) {
    var aborted, conn_pre_abort, count, detach, prerollTimeout, req;
    cb = _u.once(cb);
    aborted = false;
    if (!this.streamKey || !this.uri) {
      if (typeof cb === "function") {
        cb();
      }
      return true;
    }
    if (socket.destroyed) {
      if (typeof cb === "function") {
        cb();
      }
      return true;
    }
    count = this._counter++;
    prerollTimeout = setTimeout((function(_this) {
      return function() {
        _this.stream.log.debug("preroll request timeout. Aborting.", count);
        req.abort();
        aborted = true;
        detach();
        return typeof cb === "function" ? cb() : void 0;
      };
    })(this), 5 * 1000);
    this.stream.log.debug("firing preroll request", count, this._uri);
    req = http.get(this.uri, (function(_this) {
      return function(res) {
        _this.stream.log.debug("got preroll response ", count);
        if (res.statusCode === 200) {
          res.on("data", function(chunk) {
            return writer != null ? writer.write(chunk) : void 0;
          });
          return res.on("end", function() {
            detach();
            if (typeof cb === "function") {
              cb();
            }
            return true;
          });
        } else {
          detach();
          if (typeof cb === "function") {
            cb();
          }
          return true;
        }
      };
    })(this));
    req.on("socket", (function(_this) {
      return function(sock) {
        return _this.stream.log.debug("socket granted for ", count);
      };
    })(this));
    req.on("error", (function(_this) {
      return function(err) {
        if (!aborted) {
          _this.stream.log.debug("got a request error for ", count, err);
          detach();
          return typeof cb === "function" ? cb() : void 0;
        }
      };
    })(this));
    detach = (function(_this) {
      return function() {
        if (prerollTimeout) {
          clearTimeout(prerollTimeout);
        }
        socket.removeListener("close", conn_pre_abort);
        return socket.removeListener("end", conn_pre_abort);
      };
    })(this);
    conn_pre_abort = (function(_this) {
      return function() {
        detach();
        if (socket.destroyed) {
          _this.stream.log.debug("aborting preroll ", count);
          req.abort();
          return aborted = true;
        }
      };
    })(this);
    socket.once("close", conn_pre_abort);
    return socket.once("end", conn_pre_abort);
  };

  Preroller.prototype.connect = function() {};

  Preroller.prototype.disconnect = function() {};

  return Preroller;

})();

//# sourceMappingURL=preroller.js.map
