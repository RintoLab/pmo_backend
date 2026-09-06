This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix check` alias when you are done with all changes and fix any pending issues
- Keep `openapi.yaml` synchronized with every REST API or response-format change
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Local development and the CLI

- The production Rinto system manages this project's real tasks and documents.
  Use the installed `rinto-pmo` for that work, including while editing this repository.
- Run `mise run cli:build` before first using the development CLI and after changing
  `cli/` sources. Also rebuild after changing `skills/` when testing the CLI's embedded
  skills or its `skill install` / `skill sync` commands. The binary is
  `cli/target/debug/rinto-pmo`; this task does not install it globally.
- Run `mise run dev` to start Phoenix. It only runs `mix phx.server` with task-scoped
  environment variables; it never builds the CLI or installs skills. Building the
  CLI is a separate, explicit step, so ensure the local binary exists before testing
  a topic that invokes it.
- The development service and its Pi children resolve `rinto-pmo` through a PATH
  prefixed with `cli/target/debug`, and use
  `RINTO_CONFIG=<repository>/config/cli.json`. Keep development variables in
  task-level configuration; do not put them in mise's top-level `[env]` or change
  the terminal's global PATH.
- `RINTO_PI_SKILLS_DIR` points at this repository's `skills/server/` bundle. The
  service starts topic Pi processes with `--no-skills --skill <bundle-directory>`;
  Pi discovers the bundle's `SKILL.md` files recursively. Edit these source files
  directly, then start a new topic process to load their changes.
- Run `mise run pi:dev` for an interactive development Pi outside the server.
  It uses the local CLI, `config/cli.json`, and all source skills under `skills/`
  via `--no-skills --skill`. It does not build the CLI or start Phoenix. It fails
  when the local CLI has not been built, instead of falling through PATH to the
  production CLI. It clears
  inherited `RINTO_API`, `RINTO_TOKEN` and `RINTO_CONVERSATION_ID` so this session
  uses the selected config file and works outside a topic. Additional Pi arguments
  can be passed after `--`, for example `mise run pi:dev -- --help`.
- `skills/<bundle>/<skill>/SKILL.md` is the only source registry. The CLI build
  discovers and embeds every bundle automatically. The release workflow derives
  the production installation list from the `server` directory; do not duplicate
  individual skill names in application or deployment code.
- Run development CLI commands outside Pi with `mise run rinto-pmo:dev -- <args>`.
  This task selects `cli/target/debug/rinto-pmo` and `config/cli.json`, clears the
  same inherited connection and topic variables, and fails when the local CLI has
  not been built. For example: `mise run rinto-pmo:dev -- task list`.
- Initialize the development CLI configuration against the running local API with
  `RINTO_CONFIG="$PWD/config/cli.json" cli/target/debug/rinto-pmo config init --api http://localhost:4000/api/v1`.
  Supply the development server's token when prompted. For manual development CLI
  calls, prefix the local binary with the same `RINTO_CONFIG` variable.
- Every repository task must extend mise's `development` task template. It sources
  `.env.dev` with Bash; that file first sources `.env`, then sets development
  overrides. Copy `.env.dev.example` to `.env.dev` when setting up a checkout.
  `.env` contains shared values and is loaded into the project terminal; development
  overrides, especially `RINTO_TOKEN`, belong in `.env.dev`. Keep both files
  compatible with Bash assignments. Task-specific settings and cleared variables
  take precedence over the template's environment.
- Run `mise run check` to execute the required `mix check` alias with `.env.dev`
  loaded for that task. Other direct Mix commands that need development overrides
  must likewise receive their environment explicitly.

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- usage-rules-end -->
