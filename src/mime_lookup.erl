%% MIME Lookup, a run-time MIME type lookup service, by Martin Keegan
%%
%% To the extent (if any) permissible by law, Copyright (C) 2020  Martin Keegan
%%
%% This programme is free software; you may redistribute and/or modify it under
%% the terms of the Apache Software Licence v2.0.

%% @doc Run-time lookup of MIME types by file extension.
%%
%% The types come from a `mime.types' file (see the `mime_types_path'
%% application environment key, default `/etc/mime.types') plus any
%% extra `{Extension, MimeType}' pairs in the `mime_types' key. The extra
%% pairs override the file: see {@link lookup/1}. They are
%% read when the `mime_lookup' application starts, and again on
%% {@link reload/0}. The application must be running for either function
%% to work.
%%
%% Example:
%% <pre>
%% 1> application:ensure_all_started(mime_lookup).
%% {ok,[mime_lookup]}
%% 2> mime_lookup:lookup(&lt;&lt;"html"&gt;&gt;).
%% {ok,&lt;&lt;"text/html"&gt;&gt;}
%% 3> mime_lookup:lookup(&lt;&lt;"nosuchext"&gt;&gt;).
%% notfound
%% </pre>
%% @end
-module(mime_lookup).
-export([lookup/1, reload/0]).

%% @doc Find the MIME type for a file extension.
%%
%% The extension is a binary without the leading dot, such as
%% `<<"html">>'. The match is case-sensitive, so `<<"HTML">>' is
%% `notfound' unless the data says otherwise.
%%
%% The extra mappings override the data file: if an extension has an
%% extra mapping, its type is returned whatever the file says. If the
%% extra mappings give the same extension more than once, the first in
%% the list wins. If the data file itself gives one extension to more
%% than one type, which of them is returned is unspecified.
%%
%% An argument that is not a binary crashes the caller with
%% `function_clause'.
-spec lookup(Extension) -> Result
              when Extension :: binary(),
                   Result    :: {ok, MimeType :: binary()} | notfound.
lookup(Ext) ->
    mime_lookup_serv:lookup(Ext).

%% @doc Read the data file and the extra mappings again.
%%
%% On success the server's table is replaced; a concurrent lookup sees
%% either the old data or the new, never a mixture. On failure the old
%% data stays in use and the reason is returned. Reasons are
%% `no_mime_types_path', `{cannot_read, File, PosixReason}',
%% `{bad_mime_types, Value}' (the `mime_types' value is not a list) and
%% `{bad_extra_mapping, Entry}' (an entry is not a pair of non-empty
%% binaries).
-spec reload() -> Result
              when Result :: ok | {error, Reason :: term()}.
reload() ->
    mime_lookup_serv:reload().
