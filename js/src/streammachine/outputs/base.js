var BaseOutput, uuid, _;

_ = require("underscore");

uuid = require("node-uuid");

module.exports = BaseOutput = (function() {
  function BaseOutput(output) {
    var a_session, _ref, _ref1;
    this.client = {
      output: output
    };
    this.socket = null;
    if (this.opts.req && this.opts.res) {
      this.client.ip = this.opts.req.ip;
      this.client.path = this.opts.req.url;
      this.client.ua = _.compact([this.opts.req.param("ua"), (_ref = this.opts.req.headers) != null ? _ref['user-agent'] : void 0]).join(" | ");
      this.client.user_id = this.opts.req.user_id;
      this.client.pass_session = true;
      this.client.session_id = (a_session = (_ref1 = this.opts.req.headers) != null ? _ref1['x-playback-session-id'] : void 0) ? (this.client.pass_session = false, a_session) : this.opts.req.param("session_id") ? this.opts.req.param("session_id") : uuid.v4();
      this.socket = this.opts.req.connection;
    } else {
      this.client = this.opts.client;
      this.socket = this.opts.socket;
    }
  }

  return BaseOutput;

})();

//# sourceMappingURL=base.js.map
