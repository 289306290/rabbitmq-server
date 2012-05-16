%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2011-2012 VMware, Inc.  All rights reserved.
%%

-module(rabbit_plugins).
-include("rabbit.hrl").

-export([prepare_plugins/0, active_plugins/0, read_enabled_plugins/1,
         find_plugins/1, calculate_plugin_dependencies/3]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-spec(prepare_plugins/0 :: () -> [atom()]).
-spec(active_plugins/0 :: () -> [atom()]).
-spec(find_plugins/1 :: (string()) -> [#plugin{}]).
-spec(read_enabled_plugins/1 :: (file:filename()) -> [atom()]).
-spec(calculate_plugin_dependencies/3 ::
            (boolean(), [atom()], [#plugin{}]) -> [atom()]).

-endif.

%%----------------------------------------------------------------------------

%%
%% @doc Prepares the file system and installs all enabled plugins.
%%
prepare_plugins() ->
    {ok, PluginDir} = application:get_env(rabbit, plugins_dir),
    {ok, ExpandDir} = application:get_env(rabbit, plugins_expand_dir),
    {ok, EnabledPluginsFile} = application:get_env(rabbit,
                                                   enabled_plugins_file),
    prepare_plugins(EnabledPluginsFile, PluginDir, ExpandDir),
    [prepare_dir_plugin(PluginName) ||
            PluginName <- filelib:wildcard(ExpandDir ++ "/*/ebin/*.app")].

%% @doc Lists the plugins which are currently running.
active_plugins() ->
    {ok, ExpandDir} = application:get_env(rabbit, plugins_expand_dir),
    InstalledPlugins = [ P#plugin.name || P <- find_plugins(ExpandDir) ],
    [App || {App, _, _} <- application:which_applications(),
            lists:member(App, InstalledPlugins)].

%% @doc Get the list of plugins which are ready to be enabled.
find_plugins(PluginsDir) ->
    EZs = [{ez, EZ} || EZ <- filelib:wildcard("*.ez", PluginsDir)],
    FreeApps = [{app, App} ||
                   App <- filelib:wildcard("*/ebin/*.app", PluginsDir)],
    {Plugins, Problems} =
        lists:foldl(fun ({error, EZ, Reason}, {Plugins1, Problems1}) ->
                            {Plugins1, [{EZ, Reason} | Problems1]};
                        (Plugin = #plugin{}, {Plugins1, Problems1}) ->
                            {[Plugin|Plugins1], Problems1}
                    end, {[], []},
                    [get_plugin_info(PluginsDir, Plug) ||
                        Plug <- EZs ++ FreeApps]),
    case Problems of
        [] -> ok;
        _  -> io:format("Warning: Problem reading some plugins: ~p~n",
                        [Problems])
    end,
    Plugins.

%% @doc Read the list of enabled plugins from the supplied term file.
read_enabled_plugins(PluginsFile) ->
    case rabbit_file:read_term_file(PluginsFile) of
        {ok, [Plugins]} -> Plugins;
        {ok, []}        -> [];
        {ok, [_|_]}      -> throw({error, {malformed_enabled_plugins_file,
                                           PluginsFile}});
        {error, enoent} -> [];
        {error, Reason} -> throw({error, {cannot_read_enabled_plugins_file,
                                          PluginsFile, Reason}})
    end.

%%
%% @doc Calculate the dependency graph from <i>Sources</i>.
%% When Reverse =:= true the bottom/leaf level applications are returned in
%% the resulting list, otherwise they're skipped.
%%
calculate_plugin_dependencies(Reverse, Sources, AllPlugins) ->
    {ok, G} = rabbit_misc:build_acyclic_graph(
                fun (App, _Deps) -> [{App, App}] end,
                fun (App,  Deps) -> [{App, Dep} || Dep <- Deps] end,
                [{Name, Deps}
                 || #plugin{name = Name, dependencies = Deps} <- AllPlugins]),
    Dests = case Reverse of
                false -> digraph_utils:reachable(Sources, G);
                true  -> digraph_utils:reaching(Sources, G)
            end,
    true = digraph:delete(G),
    Dests.

%%----------------------------------------------------------------------------

prepare_plugins(EnabledPluginsFile, PluginsDistDir, DestDir) ->
    AllPlugins = find_plugins(PluginsDistDir),
    Enabled = read_enabled_plugins(EnabledPluginsFile),
    ToUnpack = calculate_plugin_dependencies(false, Enabled, AllPlugins),
    ToUnpackPlugins = lookup_plugins(ToUnpack, AllPlugins),

    Missing = Enabled -- plugin_names(ToUnpackPlugins),
    case Missing of
        [] -> ok;
        _  -> io:format("Warning: the following enabled plugins were "
                       "not found: ~p~n", [Missing])
    end,

    %% Eliminate the contents of the destination directory
    case delete_recursively(DestDir) of
        ok         -> ok;
        {error, E} -> rabbit_misc:quit("Could not delete dir ~s (~p)",
                                            [DestDir, E])
    end,
    case filelib:ensure_dir(DestDir ++ "/") of
        ok          -> ok;
        {error, E2} -> rabbit_misc:quit("Could not create dir ~s (~p)",
                                             [DestDir, E2])
    end,

    [prepare_plugin(Plugin, DestDir) || Plugin <- ToUnpackPlugins].

prepare_dir_plugin(PluginAppDescFn) ->
    %% Add the plugin ebin directory to the load path
    PluginEBinDirN = filename:dirname(PluginAppDescFn),
    code:add_path(PluginEBinDirN),

    %% We want the second-last token
    NameTokens = string:tokens(PluginAppDescFn,"/."),
    PluginNameString = lists:nth(length(NameTokens) - 1, NameTokens),
    list_to_atom(PluginNameString).

%%----------------------------------------------------------------------------

delete_recursively(Fn) ->
    case rabbit_file:recursive_delete([Fn]) of
        ok                 -> ok;
        {error, {Path, E}} -> {error, {cannot_delete, Path, E}};
        Error              -> Error
    end.

prepare_plugin(#plugin{type = ez, location = Location}, PluginDestDir) ->
    zip:unzip(Location, [{cwd, PluginDestDir}]);
prepare_plugin(#plugin{type = dir, name = Name, location = Location},
              PluginsDestDir) ->
    rabbit_file:recursive_copy(Location,
                              filename:join([PluginsDestDir, Name])).

%% Get the #plugin{} from an .ez.
get_plugin_info(Base, {ez, EZ0}) ->
    EZ = filename:join([Base, EZ0]),
    case read_app_file(EZ) of
        {application, Name, Props} -> mkplugin(Name, Props, ez, EZ);
        {error, Reason}            -> {error, EZ, Reason}
    end;
%% Get the #plugin{} from an .app.
get_plugin_info(Base, {app, App0}) ->
    App = filename:join([Base, App0]),
    case rabbit_file:read_term_file(App) of
        {ok, [{application, Name, Props}]} ->
            mkplugin(Name, Props, dir,
                     filename:absname(
                       filename:dirname(filename:dirname(App))));
        {error, Reason} ->
            {error, App, {invalid_app, Reason}}
    end.

mkplugin(Name, Props, Type, Location) ->
    Version = proplists:get_value(vsn, Props, "0"),
    Description = proplists:get_value(description, Props, ""),
    Dependencies =
        filter_applications(proplists:get_value(applications, Props, [])),
    #plugin{name = Name, version = Version, description = Description,
            dependencies = Dependencies, location = Location, type = Type}.

%% Read the .app file from an ez.
read_app_file(EZ) ->
    case zip:list_dir(EZ) of
        {ok, [_|ZippedFiles]} ->
            case find_app_files(ZippedFiles) of
                [AppPath|_] ->
                    {ok, [{AppPath, AppFile}]} =
                        zip:extract(EZ, [{file_list, [AppPath]}, memory]),
                    parse_binary(AppFile);
                [] ->
                    {error, no_app_file}
            end;
        {error, Reason} ->
            {error, {invalid_ez, Reason}}
    end.

%% Return the path of the .app files in ebin/.
find_app_files(ZippedFiles) ->
    {ok, RE} = re:compile("^.*/ebin/.*.app$"),
    [Path || {zip_file, Path, _, _, _, _} <- ZippedFiles,
             re:run(Path, RE, [{capture, none}]) =:= match].

%% Parse a binary into a term.
parse_binary(Bin) ->
    try
        {ok, Ts, _} = erl_scan:string(binary_to_list(Bin)),
        {ok, Term} = erl_parse:parse_term(Ts),
        Term
    catch
        Err -> {error, {invalid_app, Err}}
    end.

%% Filter out applications that can be loaded *right now*.
filter_applications(Applications) ->
    [Application || Application <- Applications,
                    not is_available_app(Application)].

%% Return whether is application is already available (and hence
%% doesn't need enabling).
is_available_app(Application) ->
    case application:load(Application) of
        {error, {already_loaded, _}} -> true;
        ok                           -> application:unload(Application),
                                        true;
        _                            -> false
    end.

%% Return the names of the given plugins.
plugin_names(Plugins) ->
    [Name || #plugin{name = Name} <- Plugins].

%% Find plugins by name in a list of plugins.
lookup_plugins(Names, AllPlugins) ->
    [P || P = #plugin{name = Name} <- AllPlugins, lists:member(Name, Names)].



