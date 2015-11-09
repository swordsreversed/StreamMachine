var StreamMachine, agent, core, heapdump, nconf;

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

if (nconf.get("heapdump-interval")) {
  console.log("ENABLING PERIODIC HEAP DUMPS");
  heapdump = require("heapdump");
  setInterval((function(_this) {
    return function() {
      var file;
      file = "/tmp/streammachine-" + process.pid + "-" + (Date.now()) + ".heapsnapshot";
      return heapdump.writeSnapshot(file, function(err) {
        if (err) {
          return console.error(err);
        } else {
          return console.error("Wrote heap snapshot to " + file);
        }
      });
    };
  })(this), Number(nconf.get("heapdump-interval")) * 1000);
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
