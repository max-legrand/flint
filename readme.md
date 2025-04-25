# Flint

Flint is a task runner and file watcher built with Zig. Users provide a `flint.zon` file
which defines the tasks to run and the files to watch.

Example `flint.zon` file:

```zig
.{
    .tasks = .{
        .{
            .name = "build",
            .cmd = "zig build --release=safe --summary all",
        },
    },
    .watcher = .{
        "src/*",
    },
}
```

Running `flint watch build` will re-run the `build` command every time a file in `/src` is changed.
