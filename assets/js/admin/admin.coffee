#= require_tree ./templates

class streammachine.Admin extends Backbone.Router
    routes: 
        "":                  "streams"
        "streams/:stream":   "stream"
        "slaves/:slave":     "slave"
        "slaves":            "slaves"
    
    initialize: (opts) ->
        @server = opts.server
        
        console.log "Admin init"
        
        @$el = $("#cbody")
        
        # -- set up streams models and views -- #
        
        @streams = new Admin.Streams opts.streams
        
        @sv = new Admin.StreamsView collection:@streams
        
        @_sInt = setInterval =>
            @streams.fetch update:true
        , 10000
        
        # -- set up navigation -- #
        
        @on "route:streams", =>
            @$el.html @sv.render().el
            
        @on "route:stream", (key) =>
            # make sure it's a valid stream
            if stream = @streams.find((s) -> s.get("stream") == key)
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
        
        Backbone.history.start({pushState: true})

    #----------
    
    _showStreamPage: (stream) ->
                
        view = new Admin.StreamPage model:stream
        @$el.html view.render().el

        # add navigation
        
    #----------
        
    class @Stream extends Backbone.Model
        
    class @Streams extends Backbone.Collection
        model: Admin.Stream
        url: "/api/streams"
        
    #----------
    
    class @StreamEditModal extends Backbone.View
        className: "modal stream_edit"
        template: HAML.stream_edit
        
        initialize: ->
            @modelBinder = new Backbone.ModelBinder()
            
        render: ->
            @$el.html @template @model.toJSON()
            
            @modelBinder.bind @model, @el
            
            @
    
    #----------
    
    class @StreamPage extends Backbone.View
        template: HAML.stream_page
        
        initialize: ->
            @model.on "change", => @render()
        
        render: ->
            @$el.html @template @model.toJSON()
            @
    
    #----------
    
    class @StreamView extends Backbone.View
    
    class @StreamsView extends Backbone.View
        template: HAML.streams
        
        events:
            "click .stream": "_stream"
            "click .btn-add-stream": "_add_stream"
        
        initialize: ->
            @collection.on "add remove change reset", => @render()
            
        _stream: (evt) ->
            stream = $(evt.currentTarget).data "stream"
            @trigger "stream", stream
            
        _add_stream: (evt) ->
            # create an empty stream object
            stream = new Admin.Stream
            modal = new Admin.StreamEditModal model:stream
            $(modal.render().el).modal show:true
            
            modal.on "submit", =>
                console.log "ready to submit ", stream
        
        render: ->
            @$el.html @template streams:@collection.toJSON()
            @
        
        