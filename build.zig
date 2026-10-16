const std = @import("std");

pub fn build(builder: *std.Build) !void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});
    const module = builder.addModule(
        "zigaudioparser",
        .{
            .root_source_file = builder.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );
    const opus = builder.option(bool, "opus", "Enable the libopus backend")
        orelse true;
    const vorbis = builder.option(
        bool,
        "vorbis",
        "Enable the libvorbis backend",
    )
        orelse true;
    const options = builder.addOptions();
    options.addOption(bool, "opus", opus);
    options.addOption(bool, "vorbis", vorbis);
    module.addOptions("codec_options", options);
    if (opus) {
        if (builder.lazyDependency("opus", .{})) |dep| {
            @import("build/opus.zig").add(builder, module, dep);
        }
    }
    if (vorbis) {
        if (builder.lazyDependency("vorbis", .{})) |dep| {
            @import("build/vorbis.zig")
                .add(module, dep, builder.path("src/codecs/vorbis_compat"));
        }
    }
    const example = builder.addExecutable(
        .{
            .name = "zigaudioparser-info",
            .root_module = builder.createModule(
                .{
                    .root_source_file = builder.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "zigaudioparser", .module = module },
                    },
                },
            ),
        },
    );
    builder.installArtifact(example);
    const run = builder.addRunArtifact(example);
    if (builder.args) |args| run.addArgs(args);
    builder.step("run", "Inspect and decode an audio file").dependOn(&run.step);

    const tests = builder.addTest(.{ .root_module = module });
    builder.step("test", "Run unit tests")
        .dependOn(&builder.addRunArtifact(tests).step);

    const check = builder.step("check", "Compile the example");
    check.dependOn(&example.step);
}
