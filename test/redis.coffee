RedisManager    = $src "redis"
RedisConfig     = $src "redis_config"

Redis = require "redis"

debug = require("debug")("sm:tests:redis")

REDIS_PORT = process.env.REDIS_PORT || 9999

config =
    server: "redis://localhost:#{REDIS_PORT}/1"
    key:    "SMTests"

describe "Redis", ->
    redis = null
    before (done) ->
        this.timeout 10000

        redis_args = "--port #{REDIS_PORT}"

        debug "Starting Redis instance with: #{redis_args}"
        redis_server = (require "child_process").spawn "redis-server", redis_args.split(" ")

        process.on "exit", ->
            debug "Shutting down Redis instance"
            redis_server?.kill()

        redis = Redis.createClient host:"127.0.0.1", port:REDIS_PORT
        redis.on "error", (err) ->
            debug "(Possibly harmless) Redis client error: #{err}"

        redis.once "ready", (err) ->
            throw err if err
            done()

    describe "Manager", ->
        manager = null
        it "can connect to Redis", (done) ->
            manager = new RedisManager config

            manager.once_connected -> done()

        it "selects the correct database", (done) ->
            # should be able to put a key and select it via the client we set up
            manager.client.set "TEST", "ABC"

            redis.select 1, (err) ->
                throw err if err

                redis.get "TEST", (err,val) ->
                    throw err if err
                    expect(val).to.eql "ABC"
                    done()

        it "can apply key prefix", (done) ->
            # should stick "SMTests:" on the front of our key
            pkey = manager.prefixedKey("TEST")
            expect(pkey).to.eql("#{config.key}:TEST")
            done()

    describe "Config", ->
        manager = null
        before (done) ->
            manager = new RedisManager config
            manager.once_connected -> done()

        c = null

        it "starts up and emits a config event", (done) ->
            c = new RedisConfig manager
            c.once "config", ->
                done()

        it "can store a config", (done) ->
            # we'll store our redis config object
            c._update config, (err) ->
                throw err if err
                done()

        it "can fetch a config", (done) ->
            c.once "config", (obj) ->
                expect(obj).to.eql config
                done()

            c._config()

