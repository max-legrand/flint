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
            .watcher = .{
                "src/*",
            }
            .deps = .{
                "clean",
            }
        },
        .{
            .name = "clean",
            .cmd = "rm -rf zig-out",
        }
    },
}
```

In this example, running `flint watch build` will re-run the `build` command every time a file in `/src` is changed.

Flint uses file polling to provide fast results with an emphasis on cross-platform compatibility.
