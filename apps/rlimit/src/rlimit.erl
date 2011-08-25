-module(rlimit).
%% This module implements an RED strategy layered on top of a token bucket
%% for shaping a message flow down to a user defined rate limit. Each message
%% must be assigned a symbolical size in tokens.
%%
%% The rate is measured and limited over short intervals, by default the
%% interval is set to one second.
%%
%% There is a total amount of tokens allowed to be sent or received by
%% the flow during each interval. As the the number of tokens approaches
%% that limit the probability of a message being delayed increases.
%%
%% When the amount of tokens has exceeded the limit all messages are delayed
%% until the start of the next interval.
%%
%% When the number of tokens needed for a message exceeds the number of tokens
%% allowed per interval the receiver or sender must accumulate tokens over
%% multiple intervals.

%% exported functions
-export([new/3, take/2]).

%% private functions
-export([reset/1]).


%% @doc Create a new rate limited flow.
%% @end
-spec new(atom(), non_neg_integer(), non_neg_integer()) -> ok.
new(Name, Limit, Interval) ->
    ets:new(Name, [public, named_table, set]),
    {ok, TRef} = timer:apply_interval(Interval, ?MODULE, reset, [Name]),
    ets:insert(Name, [
        {limit, Limit},
        {tokens, 0},
        {timer, TRef}]),
    ok.

%% @private Reset the token counter of a flow.
-spec reset(atom()) -> true.
reset(Name) ->
    ets:insert(Name, {tokens, 0}).



%% @doc Aquire a slot to send or receive N tokens.
%% @end
-spec take(non_neg_integer(), atom()) -> ok.
take(N, Name) when is_integer(N), N >= 0, is_atom(Name) ->
    Limit = ets:lookup_element(Name, limit, 2),
    take(N, Name, Limit).

take(N, Name, Limit) when N >= 0 ->
    case ets:update_counter(Name, tokens, {2,N}) of
        %% Limit exceeded. Keep the amount of tokens that we did
        %% manage to take before exceeding the limit.
        Tokens when Tokens >= Limit ->
            Over = Tokens - Limit,
            Under = N - Over,
            %% Hopefully, the scheduler will provide enough of a delay
            %% for the token counter to reset inbetween. If not, we'll
            %% notice this function being called a substantial number
            %% of times more than take/2.
            erlang:yield(),
            take(N-Under, Name, Limit);
        Tokens when Tokens < Limit ->
            %% Use difference between token counter and the token limit
            %% to compute the probability of a message being delayed.
            %% Add one token to the difference to ensure that a message
            %% has a 50% chance, instead of 0%, of being sent when difference
            %% is one token.
            Distance = Limit - Tokens,
            case random:uniform(Distance) of
                1 ->
                    %% Ensure that the token counter is never negative. We will loose
                    %% some tokens if the token counter was reset inbetween.
                    ets:update_counter(Name, tokens, {2,-N,0,0}),
                    erlang:yield(),
                    take(N, Name, Limit);
                _ ->
                    ok
            end
    end.
