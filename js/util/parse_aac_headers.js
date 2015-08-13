var AAC, aac, firstHeader, headerCount, _;

AAC = require("../src/streammachine/parsers/aac");

_ = require("underscore");

aac = new AAC;

firstHeader = null;

headerCount = 0;

aac.on("header", (function(_this) {
  return function(obj) {
    headerCount += 1;
    if (firstHeader) {
      if (_.isEqual(firstHeader, obj)) {

      } else {
        return console.log("Header " + headerCount + ": ", obj);
      }
    } else {
      firstHeader = obj;
      return console.log("First header: ", obj);
    }
  };
})(this));

process.stdin.pipe(aac);

//# sourceMappingURL=parse_aac_headers.js.map
