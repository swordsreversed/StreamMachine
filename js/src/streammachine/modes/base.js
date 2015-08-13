var Core, _u,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_u = require("underscore");

module.exports = Core = (function(_super) {
  __extends(Core, _super);

  function Core() {
    this.log.debug("Attaching listener for SIGUSR2 restarts.");
    process.on("SIGUSR2", (function(_this) {
      return function() {
        if (_this._restarting) {
          return false;
        }
        _this._restarting = true;
        if (_this.opts.handoff_type === "internal") {
          return _this._spawnReplacement(function(err, translator) {
            if (err) {
              _this.log.error("FATAL: Error spawning replacement process: " + err, {
                error: err
              });
              _this._restarting = false;
              return false;
            }
            return _this._sendHandoff(translator);
          });
        } else {
          if (!_this._rpc) {
            _this.log.error("Master was asked for external handoff, but there is no RPC interface");
            _this._restarting = false;
            return false;
          }
          _this.log.info("Sending process for USR2. Starting handoff via proxy.");
          return _this._rpc.request("HANDOFF_GO", null, null, {
            timeout: 20000
          }, function(err, reply) {
            if (err) {
              _this.log.error("Error handshaking handoff: " + err);
              _this._restarting = false;
              return false;
            }
            _this.log.info("Sender got handoff handshake. Starting send.");
            return _this._sendHandoff(_this._rpc);
          });
        }
      };
    })(this));
  }

  Core.prototype.streamInfo = function() {
    var k, s, _ref, _results;
    _ref = this.streams;
    _results = [];
    for (k in _ref) {
      s = _ref[k];
      _results.push(s.info());
    }
    return _results;
  };

  Core.prototype._spawnReplacement = function(cb) {
    var cp, k, new_args, newp, opts, v;
    cp = require("child_process");
    opts = require("optimist").argv;
    new_args = _u(opts).omit("$0", "_", "handoff");
    new_args = (function() {
      var _results;
      _results = [];
      for (k in new_args) {
        v = new_args[k];
        _results.push("--" + k + "=" + v);
      }
      return _results;
    })();
    new_args.push("--handoff=true");
    console.log("argv is ", process.argv, process.execPath);
    console.log("Spawning ", opts.$0, new_args);
    newp = cp.fork(process.argv[1], new_args, {
      stdio: "inherit"
    });
    newp.on("error", (function(_this) {
      return function(err) {
        return _this.log.error("Spawned child gave error: " + err, {
          error: err
        });
      };
    })(this));
    return this._handshakeHandoff(newp, cb);
  };

  Core.prototype._handshakeHandoff = function(newp, cb) {
    return new RPC(newp, (function(_this) {
      return function(err, rpc) {
        if (err) {
          cb(new Error("Failed to set up handoff RPC: " + err));
          return false;
        }
        return rpc.request("HANDOFF_GO", null, null, {
          timeout: 5000
        }, function(err, reply) {
          if (err) {
            _this.log.error("Error handshaking handoff: " + err);
            _this._restarting = false;
            return false;
          }
          _this.log.info("Sender got handoff handshake. Starting send.");
          return _this._sendHandoff(rpc);
        });
      };
    })(this));
  };

  Core.HandoffTranslator = (function(_super1) {
    __extends(HandoffTranslator, _super1);

    function HandoffTranslator(p) {
      this.p = p;
      this.p.on("message", (function(_this) {
        return function(msg, handle) {
          if (msg != null ? msg.key : void 0) {
            if (!msg.data) {
              msg.data = {};
            }
            return _this.emit(msg.key, msg.data, handle);
          }
        };
      })(this));
    }

    HandoffTranslator.prototype.send = function(key, data, handle) {
      if (handle == null) {
        handle = null;
      }
      return this.p.send({
        key: key,
        data: data
      }, handle);
    };

    return HandoffTranslator;

  })(require("events").EventEmitter);

  return Core;

})(require("events").EventEmitter);

//# sourceMappingURL=base.js.map
