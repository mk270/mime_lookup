%% MIME Lookup, a run-time MIME type lookup service, by Martin Keegan
%%
%% To the extent (if any) permissible by law, Copyright (C) 2020  Martin Keegan
%%
%% This programme is free software; you may redistribute and/or modify it under
%% the terms of the Apache Software Licence v2.0.

-module(mime_lookup).
-export([lookup/1, reload/0]).

-spec lookup(Extension) -> Result
              when Extension :: binary(),
                   Result    :: {ok, MimeType :: binary()} | notfound.
lookup(Ext) ->
    mime_lookup_serv:lookup(Ext).

-spec reload() -> Result
              when Result :: ok | {error, Reason :: term()}.
reload() ->
    mime_lookup_serv:reload().
