var StreamMachine, http, nconf, url, _u;

_u = require("underscore");

url = require('url');

http = require("http");

nconf = require("nconf");

module.exports = StreamMachine = (function() {
  function StreamMachine() {}

  StreamMachine.StandaloneMode = require("./modes/standalone");

  StreamMachine.MasterMode = require("./modes/master");

  StreamMachine.SlaveMode = require("./modes/slave");

  StreamMachine.Defaults = {
    mode: "standalone",
    handoff_type: "external",
    port: 8000,
    source_port: 8001,
    log: {
      stdout: true
    },
    ua_skip: false,
    hls: {
      segment_duration: 10,
      limit_full_index: false
    },
    analytics: {
      finalize_secs: 300
    },
    chunk_duration: 2,
    behind_proxy: false,
    cluster: 2,
    admin: {
      require_auth: false
    }
  };

  return StreamMachine;

})();

//# sourceMappingURL=index.js.map
