#= require_tree ./templates

class streammachine.Admin extends Backbone.Router
    routes: 
        "":                  "streams"
        "streams/:stream":   "stream"
        "streams":           "streams"
        "slaves/:slave":     "slave"
        "slaves":            "slaves"
        "users":             "users"
    
    initialize: (@opts) ->
        @server = opts.server
        
        console.log "Admin init"
        
        @$el = $("#cbody")
        
        # -- set up streams models and views -- #
                
        console.log "Opening streams from ", @opts.server
        @streams = new Admin.Streams @opts.streams, server:@opts.server
                
        @sv = new Admin.StreamsView collection:@streams, persisted:@opts.persisted
        
        @_sInt = setInterval =>
            @streams.fetch update:true
        , 10000
        
        # -- set up user models / views -- #
    
        @users = new Admin.Users [], server:@opts.server
        @uv = new Admin.UsersView collection:@users
        
        # -- set up navigation -- #
        
        @on "route:streams", =>
            @$el.html @sv.render().el
            
        @on "route:stream", (key) =>
            # make sure it's a valid stream
            if stream = @streams.find((s) -> s.get("key") == key)
                console.log "successful route to ", stream
                @_showStreamPage stream
                
            else
                console.log "failed to look up stream for ", key
                # jump them back to the homepage
                @navigate "/", trigger:true, replace:true
                
        @on "route:users", =>
            @$el.html @uv.render().el

        # -- wire up button listeners -- #
                
        @sv.on "stream", (stream) =>
            @navigate "/streams/#{stream}", trigger:true
                
        # -- start -- #
        
        Backbone.history.start pushState:true, root:@opts.path

    #----------
    
    _showStreamPage: (stream) ->
                
        view = new Admin.StreamPage model:stream
        @$el.html view.render().el

        # add navigation
        view.on "update", (key) =>
            @navigate "/streams/#{key}", trigger:true
            
        
    #----------
        
    class @Stream extends Backbone.Model
        
    class @Streams extends Backbone.Collection
        model: Admin.Stream
        
        initialize: (models,opts) ->
            @server = opts.server
        
        url: -> "#{@server}/streams"
        
    #----------
    
    class @StreamEditModal extends Backbone.View
        className: "modal stream_edit"
        template: JST["admin/templates/stream_edit"]
        
        events:
            "click .btn.save": "_save"
        
        initialize: ->
            @modelBinder = new Backbone.ModelBinder()
            
            if @model.isNew()
                @title = "Add a Stream"
            else
                @title = "Edit Stream: #{@model.get("key")}"
            
        _save: (evt) ->
            @trigger "save", @model
            
        render: ->
            @$el.html @template _.extend @model.toJSON(), title:@title
            
            @modelBinder.bind @model, @el
            
            @
    
    #----------
            
    class @StreamMetaModal extends Backbone.View
        className: "modal stream_meta"
        template: JST["admin/templates/stream_meta"]
    
        events:
            "click .btn.update": "_update"
    
        initialize: ->
            @modelBinder = new Backbone.ModelBinder()
        
            @title = "Update Stream Metadata"
        
        _update: (evt) ->
            @trigger "update", @model
        
        render: ->
            console.log "edit modal with ", @model.toJSON()
            @$el.html @template _.extend @model.toJSON(), title:@title
        
            @modelBinder.bind @model, @el
        
            @
    
    #----------
    
    class @StreamPage extends Backbone.View
        template: JST["admin/templates/stream_page"]
        
        events:
          "click .edit_stream":     "_edit_stream"
          "click .update_meta":     "_update_meta"
          "click .destroy_stream":  "_destroy_stream"
        
        initialize: ->
            @model.on "change", => @render()
        
        #----------
        
        render: ->
            @$el.html @template @model.toJSON()
            @
            
        #----------
            
        _edit_stream: (evt) ->
            # clone our model so that updates don't stomp on changes
            c_model = @model.clone()
            c_model.url = @model.url()
                
            modal = new Admin.StreamEditModal model:c_model
            $(modal.render().el).modal show:true

            modal.on "save", =>
                console.log "modal called save."
                o_key = c_model.get("id")
                c_model.save {}, success:(model,resp) =>
                    console.log "Successful save.", model, o_key
                    $(modal.render().el).modal "hide"
    
                    @trigger "update", c_model.get("key")
    
                , error:(model,resp) =>
                    console.log "Got an error: ", resp, model
        
        #----------
                
        _update_meta: (evt) ->
            c_model = @model.clone()
            c_model.url = @model.url()
            modal = new Admin.StreamMetaModal model:c_model
            $(modal.render().el).modal show:true
            
            modal.on "update", =>
                opts = 
                    title:  c_model.get("metaTitle")
                    url:    c_model.get("metaUrl")
                
                console.log "modal called update", opts, c_model
                $.ajax "#{c_model.url}/metadata", 
                    type: "POST"
                    data:
                        title:  c_model.get("metaTitle")
                        url:    c_model.get("metaUrl")
                    success: (data) =>
                        modal.$(".last_notice").html $ "<div/>", 
                            class:  "alert alert-success"
                            text:   "Metadata successfully updated."
                        
                    error: (xhr,resp) =>
                        modal.$(".last_notice").html $ "<div/>", 
                            class:  "alert alert-error"
                            text:   "Metadata update error: #{xhr.responseText}"
            
        #----------
          
        _destroy_stream: (evt) ->
            # ask for confirmation
            if window.confirm "Really delete the stream #{@model.get("key")}?"
                @model.destroy()
                # navigate...
    
    #----------
    
    class @StreamsView extends Backbone.View
        template: JST["admin/templates/streams"]
        
        events:
            "click .stream": "_stream"
            "click .btn-add-stream": "_add_stream"
        
        initialize: (@opts) ->
            @collection.on "add remove change reset", => @render()
            
        _stream: (evt) ->
            stream = $(evt.currentTarget).data "stream"
            @trigger "stream", stream
            
        _add_stream: (evt) ->
            # create an empty stream object
            stream = new Admin.Stream
            stream.url = @collection.url()
            stream.isNew = -> true
            modal = new Admin.StreamEditModal model:stream
            $(modal.render().el).modal show:true
            
            modal.on "save", =>
                console.log "save called on ", stream
                # try saving the new stream to the server
                stream.save {}, success:(model,res) ->
                    console.log "got success", res
                    @collection.add model
                    $(modal.render().el).modal "hide"
                    
                , error:(res) ->
                    console.log "got error: ", res
        
        render: ->
            console.log "streams collection is ", @collection.toJSON()
            @$el.html @template persisted:@opts.persisted, streams:@collection.toJSON()
            @
        
    #----------
    
    class @User extends Backbone.Model
        
    class @Users extends Backbone.Collection
        model: Admin.User
        
        initialize: (models,opts) ->
            @server = opts.server
        
        url: -> "#{@server}/users"
        
    class @UsersView extends Backbone.View
        template: JST["admin/templates/users"]
        
        events: ->
            "click .btn-update":    "_update"
            "click .btn-add":       "_add"
            "click .btn-delete":    "_remove"
        
        initialize: ->
            
        _update: (evt) ->
            
        _add: (evt) ->
            user = @$("[name=new_user]").val()
            pass = @$("[name=new_pass]").val()
            
            if @collection.get(user)
                alert("There is already a user with that name.")
            else
                obj = new Admin.User user:user, password:pass
                obj.urlRoot = @collection.url()
                
                obj.save {}, success:=>
                    @collection.add obj
                    @render()
                , error:(model,xhr) =>
                    err = JSON.parse(xhr.responseText)
                    alert "Error creating user: #{err?.error}"
            
        _remove: (evt) ->
            user = $(evt.target).data("user")
            obj = @collection.get(user)
            
            obj.destroy success:=>
                @collection.remove obj
                @render()
            , error:(model,xhr) =>
                err = JSON.parse(xhr.responseText)
                alert "Error deleting user: #{err?.error}"
            
        render: ->
            _rFunc = =>
                console.log "rendering users from ", @collection.toJSON()
                @$el.html @template users:@collection.toJSON()
            
            if @collection.length == 0
                # we haven't loaded yet
                @collection.fetch success:_rFunc
            else
                _rFunc()    
                
            @
            