// Copyright (C) 2026 tzipora-rose
//
// This file is part of petal.
//
// petal is free software: you can redistribute it and/or modify it under the
// terms of the GNU Affero General Public License, version 3, as published by
// the Free Software Foundation.
//
// petal is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
// more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with petal. If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: AGPL-3.0-only

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .windows, .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(b.addExecutable(.{ .name = "petal", .root_module = module }));

    const unit_tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run petal's unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
