# devr

Shortcuts for running PHP and Node commands in Docker Compose containers. Written in Bash, mostly for PHP and Laravel projects.

Instead of typing:

```sh
docker compose exec -u 1000 php php artisan migrate
```

use:

```sh
devr artisan migrate
```

It uses your existing Compose setup. PHP commands run in the `php` service; Yarn and npm run in `node`. You can change the service names in a project's `.devrrc`.

From your project root:

```sh
devr up                       # Start services
devr composer install         # Install PHP dependencies
devr artisan migrate          # Run database migrations
devr yarn install             # Install frontend dependencies
devr yarn dev                 # Run the frontend dev script
```

For npm projects, use `devr npm install` and `devr npm run dev`.

PHP, Composer, and Node only need to be installed in the containers.

## Setup

You'll need Bash and Docker Compose on the host. Both `docker compose` and the older `docker-compose` command are supported.

1. From this checkout, link `devr` into `~/.local/bin`:

   ```sh
   chmod +x devr
   mkdir -p "$HOME/.local/bin"
   ln -s "$PWD/devr" "$HOME/.local/bin/devr"
   ```

2. If `command -v devr` prints nothing, add `~/.local/bin` to your `PATH` in `~/.bashrc`, `~/.zshrc`, or your shell's equivalent:

   ```sh
   export PATH="$HOME/.local/bin:$PATH"
   ```

3. Open a new terminal and run `devr --help`.

Keep the checkout where it is so the symlink keeps working. You can also copy the single `devr` file into a directory on your `PATH`.

Run it as a command; don't source it into your shell.

## Commands

| Command | Runs in | Example |
| --- | --- | --- |
| `up` | Host, via `docker compose up -d` | `devr up` |
| `artisan` | PHP service | `devr artisan migrate` |
| `composer` | PHP service | `devr composer install` |
| `php` | PHP service | `devr php -v` |
| `shell [service]` | Named service, or `SHELL_DEFAULT_SERVICE` | `devr shell node` |
| `yarn` | Node service | `devr yarn install` |
| `npm` | Node service | `devr npm install` |

Arguments are passed to the underlying command, so `devr npm run build` runs `npm run build` in the Node container. `shell` takes just an optional service name.

Start the relevant service with `devr up` before running commands in it. Running `devr`, `devr -h`, or `devr --help` prints help without loading `.devrrc` or checking Docker.

### Container working directories

Commands use the container's working directory. Set `working_dir` in Compose so PHP starts where `artisan` and `composer.json` live, and Node starts where `package.json` lives. For example, those paths might be `/app` and `/app/frontend`. Yarn and npm run directly there.

### Opening a shell

```sh
devr shell          # Default service (PHP unless configured otherwise)
devr shell node
devr shell worker
```

By default, `devr` checks for Bash inside the selected container and uses it if available. Otherwise it opens `sh`. This lets a PHP container use Bash while a Node container uses `sh`. The check itself needs `sh` in the container.

To skip detection and pick a shell yourself:

```sh
SHELL_EXECUTABLE=sh devr shell node
```

An explicit executable must exist in the container; there's no fallback in this case. All container commands, including shells, use `CONTAINER_USER`.

## Configuration

Set these in a project's `.devrrc` or as environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `PHP_SERVICE` | `php` | Service for `artisan`, `composer`, and `php` |
| `NODE_SERVICE` | `node` | Compose service for `yarn` and `npm` |
| `CONTAINER_USER` | `1000` | User passed to `docker compose exec -u` |
| `SHELL_DEFAULT_SERVICE` | Value of `PHP_SERVICE` (`php` by default) | Compose service opened by `shell` when no service argument is given |
| `SHELL_EXECUTABLE` | `auto` | `auto`, `bash`, `sh`, or a shell path, without arguments |

For example, create `.devrrc` in your project root:

```sh
PHP_SERVICE=api
SHELL_DEFAULT_SERVICE=api
SHELL_EXECUTABLE=auto
```

`devr` looks for `.devrrc` in the current directory, then works up through the parent directories to `/`. It loads the first match and keeps the current working directory unchanged. It doesn't look in siblings or child directories.

Environment variables override `.devrrc`; anything unset uses the defaults above. For a one-off change:

```sh
SHELL_DEFAULT_SERVICE=worker devr shell
```

A service passed to `shell` overrides `SHELL_DEFAULT_SERVICE`, so `devr shell node` always selects `node`.

`.devrrc` is Bash code, not a plain key/value file. Only load files you trust. If loading fails, `devr` stops before calling Compose.

## Development

The tests use fake Docker commands; no containers are needed:

```sh
bash tests/run.sh
```

Check syntax and lint with [ShellCheck](https://www.shellcheck.net/):

```sh
for script in devr tests/run.sh tests/fixtures/docker tests/fixtures/node-tool tests/fixtures/shell; do
    bash -n "$script" || break
done
shellcheck devr tests/run.sh tests/fixtures/docker tests/fixtures/node-tool tests/fixtures/shell
```

## License

[MIT](LICENSE).
