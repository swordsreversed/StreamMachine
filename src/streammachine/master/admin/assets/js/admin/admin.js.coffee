#= require_tree ./templates

class streammachine.Admin extends Backbone.Router
    routes: 
        "":                  "streams"
        "streams/:stream":   "stream"
        "streams":           "streams"
        "slaves/:slave":     "slave"
        "slaves":            "slaves"
    
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

        # -- wire up button listeners -- #
                
        @sv.on "stream", (stream) =>
            @navigate "/streams/#{stream}", trigger:true
            
        @sv.on "add", =>
            # pop up an empty stream dialog
        
        # -- start -- #
        
        Backbone.history.start pushState:true, root:@opts.path

    #----------
    
    _showStreamPage: (stream) ->
                
        view = new Admin.StreamPage model:stream
        @$el.html view.render().el

        # add navigation
        
    #----------
        
    class @Stream extends Backbone.Model
        idAttribute: "key"
        
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
            console.log "edit modal with ", @model.toJSON()
            @$el.html @template _.extend @model.toJSON(), title:@title
            
            @modelBinder.bind @model, @el
            
            @
    
    #----------
    
    class @StreamPage extends Backbone.View
        template: JST["admin/templates/stream_page"]
        
        events:
          "click .edit_stream":     "_edit_stream"
          "click .destroy_stream":  "_destroy_stream"
        
        initialize: ->
            @model.on "change", => @render()
        
        render: ->
            @$el.html @template @model.toJSON()
            @
            
        _edit_stream: (evt) ->
          modal = new Admin.StreamEditModal model:@model
          $(modal.render().el).modal show:true
          
          modal.on "save", =>
            console.log "modal called save."
            @model.save {}, success:(model,resp) =>
                console.log "Successful save."
                $(modal.render().el).modal "hide"
                
            , error:(model,resp) =>
                console.log "Got an error: ", resp, model
          
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
        
        