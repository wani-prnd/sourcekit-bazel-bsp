// Copyright (c) 2025 Spotify AB.
//
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import Foundation
import LanguageServerProtocol

/// Utility that calculates the path where .o files will be stored during Bazel builds.
/// This allows the LSP to determine whether a target needs to be re-built and must
/// match exactly what's produced by Bazel / swiftc.
enum IndexOutputPathBuilder {
    struct ParsedRuleName: Equatable {
        let packagePath: String?
        let targetName: String?
        let externalRepoName: String?
    }

    /// Parses a Bazel rule name into its components.
    ///
    /// Rule name format: "//package/path:target" or "@repo//package/path:target"
    ///
    /// - Parameter ruleName: The full Bazel rule name.
    /// - Returns: A `ParsedRuleName` containing the extracted components.
    static func parseRuleName(_ ruleName: String) -> ParsedRuleName {
        guard let colonIndex = ruleName.lastIndex(of: ":") else {
            return ParsedRuleName(packagePath: nil, targetName: nil, externalRepoName: nil)
        }

        let targetName = String(ruleName[ruleName.index(after: colonIndex)...])
        let beforeColon = String(ruleName[..<colonIndex])

        // Extract external repo name if present (e.g., "@abseil-cpp" from "@abseil-cpp//absl/base")
        let externalRepoName: String?
        if beforeColon.isExternalBazelLabel() {
            var afterAt = beforeColon.dropFirst()
            while afterAt.first == "@" {
                afterAt = afterAt.dropFirst()
            }
            if let slashIdx = afterAt.firstIndex(of: "/") {
                externalRepoName = String(afterAt[..<slashIdx])
            } else {
                externalRepoName = String(afterAt)
            }
        } else {
            externalRepoName = nil
        }

        // Strip leading "@repo" if present, then strip "//"
        let withoutRepo =
            beforeColon.hasPrefix("@")
            ? String(beforeColon.drop(while: { $0 != "/" }))
            : beforeColon
        let withoutPrefix =
            withoutRepo.hasPrefix("//")
            ? String(withoutRepo.dropFirst(2))
            : withoutRepo
        let packagePath = withoutPrefix.isEmpty ? nil : withoutPrefix

        return ParsedRuleName(
            packagePath: packagePath,
            targetName: targetName,
            externalRepoName: externalRepoName
        )
    }

    /// Calculates what the output path for a source file will be.
    /// This allows the LSP to determine whether a target needs to be re-built and must
    /// match exactly what's produced by Bazel / swiftc.
    static func build(
        language: Language,
        ruleType: DependencyRuleType,
        ruleName: String,
        configMnemonic: String,
        filePath: String,
        rootUri: String,
        executionRoot: String
    ) -> String? {
        let parsed = parseRuleName(ruleName)
        let isExternal = parsed.externalRepoName != nil
        // Targets in the root package of an external repo ("@repo//:target") have no package path.
        guard let targetName = parsed.targetName, parsed.packagePath != nil || isExternal else {
            return nil
        }
        let packagePath = parsed.packagePath ?? ""
        let packageDirectory = packagePath.isEmpty ? "" : packagePath + "/"

        // Compute source path relative to package directory
        let srcRelativeToPackage: String
        if let repoName = parsed.externalRepoName,
            let repoRange = filePath.range(of: "/external/\(repoName)/"),
            filePath[repoRange.upperBound...].hasPrefix(packageDirectory)
        {
            // External files live under <outputBase>/external/<repo>/<package>/.
            srcRelativeToPackage = String(filePath[repoRange.upperBound...].dropFirst(packageDirectory.count))
        } else if filePath.hasPrefix(rootUri + "/" + packageDirectory) {
            srcRelativeToPackage = String(filePath.dropFirst(rootUri.count + 1 + packageDirectory.count))
        } else {
            // Fallback: just use the filename
            srcRelativeToPackage = (filePath as NSString).lastPathComponent
        }

        // External repos have outputs under bin/external/<repo_name>/
        let externalPrefix = parsed.externalRepoName.map { "external/\($0)/" } ?? ""
        // The rules_swift worker compiles non-WMO modules under bin/_swift_incremental/. We only observed this
        // for external targets (SPM libraries); local app targets are written directly under bin/.
        let incrementalPrefix = isExternal ? "_swift_incremental/" : ""

        switch language {
        case .swift:
            // Swift: ./bazel-out/<config>/bin/[_swift_incremental/][external/<repo>/][<package>/]<target>_objs/<srcRelative>.swift.o
            // The ./ prefix comes from -file-prefix-map $PWD=. applied by the compiler.
            return
                "./bazel-out/\(configMnemonic)/bin/\(incrementalPrefix)\(externalPrefix)\(packageDirectory)\(targetName)_objs/\(srcRelativeToPackage).o"
        case .c, .cpp, .objective_c, .objective_cpp:
            // C/ObjC: <executionRoot>/bazel-out/<config>/bin/[external/<repo>/]<package>/_objs/<target>[/arc]/<file>.o
            // Clang does NOT apply -file-prefix-map to the output path stored in index units,
            // so the path must be absolute (unlike Swift which uses ./ prefix).
            // objc_library targets put ALL files (including .c) in an /arc subdirectory.
            let fileName = (filePath as NSString).deletingPathExtension.components(separatedBy: "/").last ?? ""
            let arcSubdir = (ruleType == .objcLibrary) ? "/arc" : ""
            return
                "\(executionRoot)/bazel-out/\(configMnemonic)/bin/\(externalPrefix)\(packageDirectory)_objs/\(targetName)\(arcSubdir)/\(fileName).o"
        default:
            return nil
        }
    }
}
