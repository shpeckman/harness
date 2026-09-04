# src/cordis/context.cr
module Cordis
  # A node in the plugin tree.
  #
  # A context holds services, event subscriptions and effects. Mounting a
  # plugin creates a child context; service lookups walk up to ancestors, and
  # emitted events bubble up to ancestor listeners. Disposing a context
  # disposes its children and unwinds every effect registered in it — which
  # is what makes "everything is a plugin" safe: nothing a plugin did
  # survives its unload.
  class Context
    getter name   : String
    getter parent : Context?

    @services = {} of String => Service
    @emitter  = Emitter.new
    @scope    = CompositeDisposable.new
    @children = [] of Context
    @disposed = false

    def initialize(@parent : Context? = nil, @name : String = "root")
    end

    def disposed? : Bool
      @disposed
    end

    # --- services ---------------------------------------------------------

    # Register a service under `key`. Services live in one shared registry
    # at the tree's root — plugins contribute services to a shared context —
    # while the *unregistration* effect stays scoped to the registering
    # context, so a plugin's services disappear when it unloads. When two
    # registrations share a key, the later one wins and unwinding it
    # restores the earlier.
    def []=(key : String, service : Service) : Disposable
      check_alive!
      holder   = root_context
      previous = holder.@services[key]?
      holder.@services[key] = service
      effect do
        if previous
          holder.@services[key] = previous
        else
          holder.@services.delete(key)
        end
      end
    end

    # Fetch a service, walking up the tree. Returns nil when absent.
    def []?(key : String) : Service?
      @services[key]? || @parent.try(&.[]?(key))
    end

    # Fetch a service, walking up the tree. Raises when absent.
    def [](key : String) : Service
      self[key]? || raise KeyError.new("no Cordis service registered under #{key.inspect}")
    end

    # Typed fetch: `ctx.service("tools", Harness::Tools)`.
    def service(key : String, type : T.class) : T forall T
      self[key].as(T)
    end

    # Typed fetch or nil: `ctx.service?("approval", Harness::Approval)`.
    def service?(key : String, type : T.class) : T? forall T
      self[key]?.try(&.as(T))
    end

    # --- events -----------------------------------------------------------

    # Subscribe to an event name. The subscription unwinds with this context.
    def on(name : String, &block : Event -> Nil) : Disposable
      check_alive!
      @scope.push(@emitter.on(name, &block))
    end

    # Typed subscribe: `ctx.on(Harness::AgentFinish) { |e| ... }`.
    def on(event_type : E.class, &block : E -> Nil) : Disposable forall E
      on(E::NAME) { |event| block.call(event.as(E)) }
    end

    # Subscribe once.
    def once(name : String, &block : Event -> Nil) : Disposable
      check_alive!
      @scope.push(@emitter.once(name, &block))
    end

    # Emit on this context, then bubble to ancestors (Cordis tree semantics:
    # a listener sees events from its own context and everything below it).
    def emit(event : Event) : Nil
      @emitter.deliver(event)
      @parent.try(&.emit(event))
    end

    # --- effects ----------------------------------------------------------

    # Register a reversible effect in this context. The block runs when the
    # returned disposable — or this whole context — is disposed.
    def effect(&block : -> Nil) : Disposable
      check_alive!
      @scope.push(CallbackDisposable.new(block))
    end

    # Take ownership of a disposable: it is disposed when this context
    # unloads. Use it to tie registrations made on *other* objects (e.g. a
    # tool registered in the shared registry) to this plugin's lifetime.
    def own(d : D) : D forall D
      check_alive!
      @scope.push(d)
    end

    # --- plugin tree ------------------------------------------------------

    # Mount a registered plugin as a child of this context. Returns the
    # plugin's own context. If the factory raises, the half-mounted child is
    # fully unwound before the error propagates.
    def mount(plugin : String, config : YAML::Any = YAML::Any.new(nil)) : Context
      check_alive!
      factory = Cordis.plugin?(plugin) ||
                raise ArgumentError.new("unknown plugin #{plugin.inspect} (registered: #{Cordis.plugin_names.join(", ")})")
      child = Context.new(self, plugin)
      begin
        factory.call(child, config)
      rescue ex
        child.dispose
        raise ex
      end
      @children << child
      child
    end

    # Dispose children (newest first), then unwind this context's own
    # effects. Idempotent.
    def dispose : Nil
      return if @disposed
      @disposed = true
      @children.reverse_each(&.dispose)
      @children.clear
      @scope.dispose
    end

    # The topmost context of this tree; owns the shared service registry.
    protected def root_context : Context
      @parent.try(&.root_context) || self
    end

    private def check_alive! : Nil
      raise "context #{@name.inspect} is disposed" if @disposed
    end
  end
end
