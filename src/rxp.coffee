
# special value for promise not yet having a value. this is since we
# handled undefined as well.
INI = {ini:0}

# special value used to propagate through promise chain to signal end.
FIN = {fin:0}

cnt = 0

module.exports = class RxP

    _value:     INI      # the current value
    _isError:   false    # whether the value is an error
    _isEnded:   false    # whether stream is ended
    _isEnding:  false    # something indicated stream is ending.
    _type:      'root'   # type of promise (then, fail, always etc)
    _resolver:  null     # the resolver for this step
    _fx:        null     # function for resolving a value
    _fe:        null     # function for resolving an error
    _prev:      null     # the previous promise in a chain
    _next:      null     # the next promises in a chain
    _execCount: 0        # number of (unresolved) executing events.

    inspect: ->
        v = if @_value == INI then '_' else @_value + ''
        "{#{@_type}#{@_cnt}: v:#{v}, err:#{@_isError}, end:#{@_isEnded}, exec:#{@_execCount}}"

    constructor: (v) ->
        return new RxP(v) unless this instanceof RxP

        @_cnt = cnt++

        if v instanceof RxP
            # We chain ourselves to the given promise.
            # I.e. RxP(RxP(42)) is the same value as RxP(42).
            v._addNext this
        else
            # Given a real value, we are already resolved.
            @_value   = v
            @_isError = a if typeof (a = arguments[1]) == 'boolean'
            @_isEnded = v != INI

    @reject: (reason) -> new RxP(reason, true)
    @defer:  (v) -> new RxP(INI)._defer(v)

    isPending:   -> not @_isEnded
    isEnded:     -> @_isEnded
    isRejected:  -> @_isEnded and @_isError
    isFulfilled: -> @_isEnded and not @_isError

    # make a facade
    _defer: (v) ->
        @_push v if v isnt undefined
        _this = this
        @_def || @_def = {
            push:      _this._push
            pushError: _this._pushError
            resolve:   _this._resolve
            reject:    _this._reject
            end:       _this._end
            promise:   _this
        }

    # deliberately bound methods
    _push:      (v) => @_exec v, false
    _pushError: (e) => @_exec e, true
    _resolve:   (v) => @_push(v)._end()
    _reject:    (e) => @_pushError(e)._end()
    _end:           => @_exec FIN, false

    _exec: (v, isError) ->
#        console.log 'exec', v, isError, @inspect()
        # no more pushing to finished value
        return this if @_isEnded or @_isEnding
        # last value sets isEnded and is propagated
        if v == FIN
            @_isEnding = true
            if @_execCount == 0 then @_doEnd() else @_doEndOnResolverExit = true
            return this
        @_execCount++
        unless @_resolver @_fx, @_fe, v, isError, @_resolverExit, @_resolverErr
            # resolver did not handle the value => set incoming
            @_resolverExit v, isError
        this

    # decreases exec count and sets the value.
    _resolverExit: (v, isErr) => # deliberate bind
#        console.log 'resolverExit', v, @inspect()
        @_execCount--
        @_setValue v, isErr
        @_doEnd() if @_doEndOnResolverExit and @_execCount == 0

    # exit resolver with an error
    _resolverErr: (err) =>
#        console.log 'resolverErr', v, @inspect()
        @_execCount--
        @_setValue err, true
        @_doEnd() if @_doEndOnResolverExit and @_execCount == 0

    # does the actual ending of a promise. may be called deferred if
    # promise is waiting to resolve.
    _doEnd: => # deliberate bind
#        console.log 'doEnd', @inspect()
        @_isEnded = true
        @_prev?._removeNext this
        @_forward FIN, false
        return this

    # the no op resolver is default
    _resolver: (fx, fe, v, isError, cb) ->
#        console.log '_resolver', @inspect()
        unwrap v, isError, cb
        # cb v, isError
        return true

    # sets the value and propagates to chained promises
    _setValue: (v, isError) ->
#        console.log 'setValue', v, @inspect()
        return this if @_isEnded # ended takes no more values
        @_value   = v
        @_isError = isError
        @_forward v, isError

    # propagates the given value/error to chained promises _exec
    # functions.
    _forward: (v, isError) ->
#        console.log 'forward', v, isError, @_next, @inspect()
        return this unless @_next?.length
        @_next.forEach (n) -> n._exec v, isError
        this

    # Adds the given chained promise to this one. Returns the chained.
    _addNext: (n) ->
#        console.log 'addNext', n._type, @inspect()
        @_next = [] unless @_next
        @_next.push n
        n._prev = this
        unless @_value == INI
            n._exec @_value, @_isError
            n._exec FIN, false if @_isEnded and not n._isEnded
        return n

    # Removes the given chained promise from this one.
    _removeNext: (n) ->
        delete n._prev
        @_next.splice i, 1 if i = @_next.indexOf(n) >= 0
        this


# mode for finally/fin/always
ALWAYS = {always:0}

# helper for doing process.nextTick in a platform independent way.
nextTick = require './nexttick'

# Creates .then-style resolvers (then, fail, always).
makeResolver = (mode) -> (fx, fe, v, isError, cb, ce) ->
    f = if mode == ALWAYS or mode == isError
        fx
    else if mode == false and isError == true
        fe
    return false unless f
    _this = this
    nextTick ->
        try
            r = f.apply undefined, if mode == ALWAYS then [v, isError] else [v]
            throw new TypeError('f returned same promise') if r == _this
            unwrap r, false, cb
        catch err
            ce err
    return true

# special error
class TypeError extends Error
    constructor: -> super

# Makes a new promise chained off this with given resolver.
stepWith = (type, resolver, twoF, finish) -> (fx,fe) ->
    p = new RxP(INI)
    p._type = type
    p._resolver = resolver
    p._fx = fx
    p._fe = fe if twoF
    @_addNext p
    return if finish then undefined else p

# create standard step functions and their aliases
thenResolver   = makeResolver false
failResolver   = makeResolver true
alwaysResolver = makeResolver ALWAYS
RxP::then    = RxP::map   = stepWith 'then', thenResolver, true
RxP::fail    = RxP::catch = stepWith 'fail', failResolver
RxP::always  = RxP::fin = RxP::finally = stepWith 'always', alwaysResolver
# internal always-resolver to not confuse things
RxP::_always = stepWith '[always]', alwaysResolver

# spread is like then
RxP::spread = stepWith 'spread', (fx, fe, v, isError, cb, ce) ->
    # presumably we use spread to unpack an array in v, but we handle
    # single values too.
    argv = if Array.isArray(v) then v else [v]
    f = -> fx.apply undefined, argv
    return thenResolver.call this, f, undefined, v, isError, cb, ce

# done method is special, because it bubbles any exceptions.
doneResolver = (fx, fe, v, isError, cb, ce) ->
    if isError and not fe
        fe = -> nextTick -> throw (if v instanceof Error then v else new Error(v))
        fe = process.domain.bind(fe) if process?.domain?
    return thenResolver.call this, fx, fe, v, isError, cb, ce
RxP::done = stepWith 'done', doneResolver, true, true

RxP::serial = stepWith 'serial', (fx, fe, v, isError, cb, ce) ->
    s = @_serial = [] unless s = @_serial
    s.push Array.prototype.slice.call(arguments, 0)
    step = ->
        argv = s.shift()
        return unless argv
        icb = argv[4]
        argv[4] = (v, isError) ->
            icb v, isError
            step()
        unwrap argv[2], argv[3], (v, isError) ->
            argv[2] = v
            argv[3] = isError
            thenResolver.apply this, argv
    step()
    return true

# Recursively unwrapp the given value. Callback when we got to the
# bottom of it.
unwrap = (v, isError, cb) ->
    if v instanceof RxP
        v._always (v, isError) ->
            unwrap v, isError, cb
            return null # important or we get endless loops
    else
        cb v, isError