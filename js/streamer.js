var StreamMachine, agent, core, nconf;

StreamMachine = require("./src/streammachine");

nconf = require("nconf");

nconf.env().argv();

nconf.file({
  file: nconf.get("config") || nconf.get("CONFIG") || "/etc/streammachine.conf"
});

nconf.defaults(StreamMachine.Defaults);

if (nconf.get("enable-webkit-devtools")) {
  console.log("ENABLING WEBKIT DEVTOOLS");
  agent = require("webkit-devtools-agent");
  agent.start();
}

core = (function() {
  switch (nconf.get("mode")) {
    case "master":
      return new StreamMachine.MasterMode(nconf.get());
    case "slave":
      return new StreamMachine.SlaveMode(nconf.get());
    default:
      return new StreamMachine.StandaloneMode(nconf.get());
  }
})();

//# sourceMappingURL=streamer.js.map
