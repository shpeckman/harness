# src/cordis/service.cr
module Cordis
  # Base class for anything mountable as a context service. Crystal needs a
  # concrete common ancestor for heterogeneous storage, so services inherit
  # this; the typed accessors (`Context#service`) cast back for you.
  abstract class Service
  end
end
