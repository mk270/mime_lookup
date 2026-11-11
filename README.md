# mime_lookup

A small OTP application that looks up the MIME type of a file from its
extension, at run time.

```erlang
1> application:ensure_all_started(mime_lookup).
{ok,[mime_lookup]}
2> mime_lookup:lookup(<<"html">>).
{ok,<<"text/html">>}
3> mime_lookup:lookup(<<"gmi">>).
{ok,<<"text/gemini">>}
4> mime_lookup:lookup(<<"nosuchext">>).
notfound
```

The types come from a `mime.types` file (by default `/etc/mime.types`)
plus any extra mappings you put in the application environment. They are
read when the application starts, and again whenever you call
`mime_lookup:reload/0`.

## Installing

Add it to your `rebar.config`:

```erlang
{deps, [{mime_lookup, "~> 0.3.1"}]}.
```

and list `mime_lookup` among the `applications` of your own application
(in its `.app.src`), so that it is started before yours.

## Looking up a type

```erlang
-spec mime_lookup:lookup(Extension) -> {ok, MimeType} | notfound
          when Extension :: binary(), MimeType :: binary().
```

- The extension is a **binary, without the leading dot**: `<<"html">>`,
  not `<<".html">>` or `"html"`.
- It is **case-sensitive**: the data files write extensions in lower case,
  so `<<"HTML">>` gives `notfound`. Lower-case it first if you need to.
- Anything that is not a binary is a programming error and crashes the
  caller (`function_clause`).
- If more than one type claims the same extension, one of them is
  returned; which is not specified.

All lookups go through a single server process, so the application must be
running.

## Where the data comes from

**The data file**, named by the `mime_types_path` setting (default
`/etc/mime.types`). Each line is a MIME type followed by the extensions it
is known by, separated by spaces or tabs. Anything after a `#` is a
comment. A line that names no extension, including a blank line, maps
nothing and is ignored.

```
# a comment
text/html           html htm
text/x-demo         demo dm
application/x-noext
```

**Extra mappings**, in the `mime_types` setting: a list of
`{Extension, MimeType}` pairs, which are added to the file's. The default
adds `gemini` and `gmi` for `text/gemini`.

| Setting | Default | Meaning |
|---|---|---|
| `mime_types_path` | `"/etc/mime.types"` | the data file |
| `mime_types` | `gemini`, `gmi` | extra `{Extension, MimeType}` mappings |

In `sys.config`:

```erlang
{mime_lookup, [
    {mime_types_path, "/usr/local/etc/mime.types"},
    {mime_types, [{<<"gmi">>, <<"text/gemini">>},
                  {<<"mydoc">>, <<"text/x-mine">>}]}
]}.
```

Both the extension and the type in each extra mapping must be **non-empty
binaries** (strings and atoms are not accepted), and `mime_types` must be
a proper list. Anything else is an error, rather than being quietly
ignored or stored where it could never be found.

## Reloading

```erlang
5> mime_lookup:reload().
ok
```

`reload/0` reads the data file and the extra mappings again and replaces
what the server holds. Lookups made meanwhile see either the old data or
the new, never a mixture. If something is wrong, the old data stays in use
and you are told why:

```erlang
6> mime_lookup:reload().      %% mime_types_path points at a missing file
{error,{cannot_read,"/no/such/file",enoent}}
7> mime_lookup:reload().      %% an extra mapping given as strings
{error,{bad_extra_mapping,{"mydoc","text/x-mine"}}}
```

The other errors are `no_mime_types_path` (no data file configured) and
`{bad_mime_types, Value}` (`mime_types` is not a list).

## Starting

The data is loaded before the application finishes starting, so a lookup
is possible the moment `application:start/1` returns. If the data cannot be
loaded, the application does not start: the usual supervisor error comes
back, with the reason (such as `{cannot_read, File, enoent}`) inside it.

## Developing

```
$ rebar3 compile
$ rebar3 eunit
$ rebar3 dialyzer
```

## Licence

Apache 2.0; see the `LICENCE` file. Copyright (C) 2020 Martin Keegan.

Source: <https://github.com/mk270/mime_lookup>
