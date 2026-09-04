# src/cordis/disposable.cr
module Cordis
  # A reversible registration. Disposing undoes whatever the effect did:
  # unregister the service, remove the event listener, unmount the child.
  # Disposal is idempotent.
  abstract class Disposable
    @disposed = false

    def disposed? : Bool
      @disposed
    end

    def dispose : Nil
      return if @disposed
      @disposed = true
      perform
    end

    protected def perform : Nil
    end
  end

  # A disposable backed by a cleanup block.
  class CallbackDisposable < Disposable
    def initialize(@callback : -> Nil)
    end

    def initialize(&block : -> Nil)
      @callback = block
    end

    protected def perform : Nil
      @callback.call
    end
  end

  # A stack of disposables, unwound in reverse registration order (LIFO),
  # mirroring how effects nest in a plugin tree.
  class CompositeDisposable < Disposable
    @children = [] of Disposable

    def push(d : D) : D forall D
      @children << d
      d
    end

    def size : Int32
      @children.size
    end

    protected def perform : Nil
      @children.reverse_each(&.dispose)
      @children.clear
    end
  end
end
