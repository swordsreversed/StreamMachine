var EventEmitter, Redis, RedisConfig, Url, _u,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_u = require('underscore');

Redis = require('redis');

Url = require("url");

EventEmitter = require('events').EventEmitter;

module.exports = RedisConfig = (function(_super) {
  __extends(RedisConfig, _super);

  function RedisConfig(redis) {
    this.redis = redis;
    this._config();
  }

  RedisConfig.prototype._config = function() {
    return this.redis.once_connected((function(_this) {
      return function(client) {
        console.log("Querying config from Redis");
        return client.get(_this.redis.prefixedKey("config"), function(err, reply) {
          var config;
          if (reply) {
            config = JSON.parse(reply.toString());
            console.log("Got redis config of ", config);
            return _this.emit("config", config);
          }
        });
      };
    })(this));
  };

  RedisConfig.prototype._update = function(config) {
    return this.redis.once_connected((function(_this) {
      return function(client) {
        console.log("Saving configuration to Redis");
        return client.set(_this.redis.prefixedKey("config"), JSON.stringify(config), function(err, reply) {
          if (err) {
            return console.log("Redis: Failed to save updated config: " + err);
          } else {
            return console.log("Set config to ", config, reply);
          }
        });
      };
    })(this));
  };

  return RedisConfig;

})(EventEmitter);

//# sourceMappingURL=redis_config.js.map
