PasswordHash = require "password-hash"

module.exports = class Users
    constructor: ->
        @_user_lookup = (user,password,cb) =>
            cb? "Cannot look up users without a valid store loaded."

        @_user_store = (user,password,cb) =>
            cb? "Cannot store users without a valid store loaded."
        
    validate: (user,password,cb) ->
        @_user_lookup user, password, cb
        
    store: (user,password,cb) ->
        @_user_store user, password, cb
    
    #-----------
        
    class @Local extends Users
        constructor: (@admin) ->
            super
            
            if @admin.core.redis?
                # we're using redis for users
                #@admin.core.redis.once_connected
                @_user_lookup = (user,password,cb) =>
                    @admin.core.redis.once_connected (redis) =>
                        redis.hget "users", user, (err,val) =>
                            if err
                                cb? err
                                return false
                            
                            # see if the hashed passwords match
                            if PasswordHash.verify(password,val)
                                # good to go
                                cb? null, true
                                
                            else
                                cb? null, false
                                
                @_user_store = (user,password,cb) =>
                    @admin.core.redis.once_connected (redis) =>
                        hashed = PasswordHash.generate password
                        
                        redis.hset "users", user, (err) =>
                            if err
                                cb? err
                                return false
                                
                            cb? null, true
                
            else
                # we need to pull users out of the config file
                nconf = require "nconf"
                
                @_user_lookup = (user,password,cb) =>
                    if hash = nconf.get("users:#{user}")
                        cb? null, PasswordHash.verify(password,hash)
                    else
                        cb? "User not found."
                
            
                @_user_store = (user,password,cb) =>
                    cb? "Cannot store passwords when not using Redis."
            