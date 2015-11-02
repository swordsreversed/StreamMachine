var Preroller, debug, http, request, url, xmldom, xpath, _,
  __slice = [].slice;

_ = require("underscore");

http = require("http");

url = require("url");

request = require("request");

xmldom = require("xmldom");

xpath = require("xpath");

debug = require("debug")("sm:slave:preroller");

module.exports = Preroller = (function() {
  function Preroller(stream, key, uri, transcode_uri, cb) {
    this.stream = stream;
    this.key = key;
    this.uri = uri;
    this.transcode_uri = transcode_uri;
    this._counter = 1;
    this.stream.log.debug("Preroller calling getStreamKey");
    this.stream.getStreamKey((function(_this) {
      return function(streamKey) {
        _this.streamKey = streamKey;
        return _this.stream.log.debug("Preroller: Stream key is " + _this.streamKey + ". Ready to start serving.");
      };
    })(this));
    if (typeof cb === "function") {
      cb(null, this);
    }
  }

  Preroller.prototype.pump = function(client, socket, writer, cb) {
    var aborted, adreq, conn_pre_abort, count, detach, pdebug, prerollTimeout, treq, uri;
    cb = _.once(cb);
    aborted = false;
    if (!this.streamKey || !this.uri) {
      cb(new Error("Preroll request before streamKey or missing URI."));
      return true;
    }
    if (socket.destroyed) {
      cb(new Error("Preroll request got destroyed socket."));
      return true;
    }
    count = this._counter++;
    pdebug = function() {
      var args, msg;
      msg = arguments[0], args = 2 <= arguments.length ? __slice.call(arguments, 1) : [];
      return debug.apply(null, ["" + count + ": " + msg].concat(__slice.call(args)));
    };
    prerollTimeout = setTimeout((function(_this) {
      return function() {
        _this.stream.log.debug("preroll request timeout. Aborting.", count);
        pdebug("Hit timeout. Triggering abort.");
        if (typeof adreq !== "undefined" && adreq !== null) {
          adreq.abort();
        }
        if (typeof treq !== "undefined" && treq !== null) {
          treq.abort();
        }
        aborted = true;
        return detach(new Error("Preroll request timed out."));
      };
    })(this), 5 * 1000);
    uri = this.uri.replace("!KEY!", this.streamKey).replace("!IP!", client.ip).replace("!STREAM!", this.key).replace("!UA!", encodeURIComponent(client.ua)).replace("!UUID!", client.session_id);
    pdebug("Ad request URI is " + uri);
    treq = null;
    adreq = request.get(uri, (function(_this) {
      return function(err, res, body) {
        var perr;
        if (err) {
          perr = new Error("Ad request returned error: " + err);
          _this.stream.log.error(perr, {
            error: err
          });
          pdebug(perr);
          return detach(perr);
        }
        if (res.statusCode === 200) {
          return new Preroller.AdObject(body, function(err, obj) {
            if (err) {
              perr = "Ad request was unsuccessful: " + err;
              _this.stream.log.debug(perr);
              pdebug(perr);
              return detach(err);
            }
            if (obj.creativeURL) {
              pdebug("Preparing transcoder request for " + obj.creativeURL + " with key " + _this.streamKey + ".");
              return treq = request.get(_this.transcode_uri, {
                qs: {
                  uri: obj.creativeURL,
                  key: _this.streamKey
                }
              }).once("response", function(resp) {
                pdebug("Transcoder response received: " + resp.statusCode);
                if (resp.statusCode === 200) {
                  treq.pipe(writer, {
                    end: false
                  });
                  return treq.once("end", function() {
                    pdebug("Transcoder pipe complete.");
                    return detach(null, function() {
                      if (obj.impressionURL) {
                        return request.get(obj.impressionURL, function(err, resp, body) {
                          if (err) {
                            return _this.stream.log.error("Failed to hit impression URL " + obj.impressionURL + ": " + err);
                          } else {
                            return pdebug("Impression URL hit successfully.");
                          }
                        });
                      } else {
                        _this.stream.log.debug("Session reached preroll impression criteria, but no impression URL present.");
                        return pdebug("No impression URL found.");
                      }
                    });
                  });
                } else {
                  err = new Error("Non-200 response from transcoder.");
                  pdebug(err);
                  return detach(err);
                }
              }).once("error", function(err) {
                pdebug("Transcoder request error: " + err);
                return detach(err);
              });
            } else {
              return detach();
            }
          });
        } else {
          perr = new Error("Ad request returned non-200 response: " + body);
          _this.stream.log.debug(perr);
          pdebug(perr);
          return detach(perr);
        }
      };
    })(this));
    detach = _.once((function(_this) {
      return function(err, impcb) {
        pdebug("In detach");
        if (prerollTimeout) {
          clearTimeout(prerollTimeout);
        }
        socket.removeListener("close", conn_pre_abort);
        socket.removeListener("end", conn_pre_abort);
        return cb(err, impcb);
      };
    })(this));
    conn_pre_abort = (function(_this) {
      return function() {
        detach();
        if (socket.destroyed) {
          pdebug("Aborting");
          _this.stream.log.debug("aborting preroll ", count);
          if (adreq != null) {
            adreq.abort();
          }
          if (treq != null) {
            treq.abort();
          }
          return aborted = true;
        }
      };
    })(this);
    socket.once("close", conn_pre_abort);
    return socket.once("end", conn_pre_abort);
  };

  Preroller.AdObject = (function() {
    function AdObject(xmldoc, cb) {
      var ad, creative, doc, impression, mediafile, wrapper, _ref, _ref1, _ref2, _ref3, _ref4, _ref5;
      this.creativeURL = null;
      this.impressionURL = null;
      this.doc = null;
      debug("Parsing ad object XML");
      doc = new xmldom.DOMParser().parseFromString(xmldoc);
      debug("XML doc parsed.");
      if (wrapper = (_ref = xpath.select("/VAST", doc)) != null ? _ref[0] : void 0) {
        debug("VAST wrapper detected");
        if (ad = (_ref1 = xpath.select("Ad/InLine", wrapper)) != null ? _ref1[0] : void 0) {
          debug("Ad document found.");
          if (creative = (_ref2 = xpath.select("./Creatives/Creative/Linear", ad)) != null ? _ref2[0] : void 0) {
            if (mediafile = xpath.select("string(./MediaFiles/MediaFile[@type='audio/mpeg']/text())", creative)) {
              debug("MP3 Media File is " + mediafile);
              this.creativeURL = mediafile;
            } else if (mediafile = xpath.select("string(./MediaFiles/MediaFile[@type='audio/mp4']/text())", creative)) {
              debug("MP4 Media File is " + mediafile);
              this.creativeURL = mediafile;
            }
          }
          if (impression = xpath.select("string(./Impression/text())", ad)) {
            debug("Impression URL is " + impression);
            this.impressionURL = impression;
          }
          return cb(null, this);
        } else {
          return cb(null, null);
        }
      }
      if (wrapper = (_ref3 = xpath.select("/DAAST", doc)) != null ? _ref3[0] : void 0) {
        debug("DAAST wrapper detected");
        if (ad = (_ref4 = xpath.select("Ad/InLine", wrapper)) != null ? _ref4[0] : void 0) {
          debug("Ad document found.");
          if (creative = (_ref5 = xpath.select("./Creatives/Creative/Linear", ad)) != null ? _ref5[0] : void 0) {
            if (mediafile = xpath.select("string(./MediaFiles/MediaFile[@type='audio/mpeg']/text())", creative)) {
              debug("MP3 Media File is " + mediafile);
              this.creativeURL = mediafile;
            } else if (mediafile = xpath.select("string(./MediaFiles/MediaFile[@type='audio/mp4']/text())", creative)) {
              debug("MP4 Media File is " + mediafile);
              this.creativeURL = mediafile;
            }
          }
          if (impression = xpath.select("string(./Impression/text())", ad)) {
            debug("Impression URL is " + impression);
            this.impressionURL = impression;
          }
          return cb(null, this);
        } else {
          return cb(null, null);
        }
      }
      cb(new Error("Unsupported ad format"));
    }

    return AdObject;

  })();

  return Preroller;

})();

//# sourceMappingURL=preroller.js.map
