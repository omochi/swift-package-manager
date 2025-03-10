//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import CoreCommands
import Foundation
import PackageModel
import SPMBuildCore

import class TSCBasic.BufferedOutputByteStream
import class TSCBasic.Process

final class PluginDelegate: PluginInvocationDelegate {
    let swiftTool: SwiftTool
    let plugin: PluginTarget
    var lineBufferedOutput: Data

    init(swiftTool: SwiftTool, plugin: PluginTarget) {
        self.swiftTool = swiftTool
        self.plugin = plugin
        self.lineBufferedOutput = Data()
    }

    func pluginCompilationStarted(commandLine: [String], environment: EnvironmentVariables) {
    }

    func pluginCompilationEnded(result: PluginCompilationResult) {
    }

    func pluginCompilationWasSkipped(cachedResult: PluginCompilationResult) {
    }

    func pluginEmittedOutput(_ data: Data) {
        lineBufferedOutput += data
        while let newlineIdx = lineBufferedOutput.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = lineBufferedOutput.prefix(upTo: newlineIdx)
            print(String(decoding: lineData, as: UTF8.self))
            lineBufferedOutput = lineBufferedOutput.suffix(from: newlineIdx.advanced(by: 1))
        }
    }

    func pluginEmittedDiagnostic(_ diagnostic: Basics.Diagnostic) {
        swiftTool.observabilityScope.emit(diagnostic)
    }

    func pluginRequestedBuildOperation(
        subset: PluginInvocationBuildSubset,
        parameters: PluginInvocationBuildParameters,
        completion: @escaping (Result<PluginInvocationBuildResult, Error>) -> Void
    ) {
        // Run the build in the background and call the completion handler when done.
        DispatchQueue.sharedConcurrent.async {
            completion(Result {
                return try self.performBuildForPlugin(subset: subset, parameters: parameters)
            })
        }
    }

    private func performBuildForPlugin(
        subset: PluginInvocationBuildSubset,
        parameters: PluginInvocationBuildParameters
    ) throws -> PluginInvocationBuildResult {
        // Configure the build parameters.
        var buildParameters = try self.swiftTool.buildParameters()
        switch parameters.configuration {
        case .debug:
            buildParameters.configuration = .debug
        case .release:
            buildParameters.configuration = .release
        }
        buildParameters.flags.cCompilerFlags.append(contentsOf: parameters.otherCFlags)
        buildParameters.flags.cxxCompilerFlags.append(contentsOf: parameters.otherCxxFlags)
        buildParameters.flags.swiftCompilerFlags.append(contentsOf: parameters.otherSwiftcFlags)
        buildParameters.flags.linkerFlags.append(contentsOf: parameters.otherLinkerFlags)

        // Configure the verbosity of the output.
        let logLevel: Basics.Diagnostic.Severity
        switch parameters.logging {
        case .concise:
            logLevel = .warning
        case .verbose:
            logLevel = .info
        case .debug:
            logLevel = .debug
        }

        // Determine the subset of products and targets to build.
        var explicitProduct: String? = .none
        let buildSubset: BuildSubset
        switch subset {
        case .all(let includingTests):
            buildSubset = includingTests ? .allIncludingTests : .allExcludingTests
        case .product(let name):
            buildSubset = .product(name)
            explicitProduct = name
        case .target(let name):
            buildSubset = .target(name)
        }

        // Create a build operation. We have to disable the cache in order to get a build plan created.
        let outputStream = BufferedOutputByteStream()
        let buildSystem = try swiftTool.createBuildSystem(
            explicitBuildSystem: .native,
            explicitProduct: explicitProduct,
            cacheBuildManifest: false,
            customBuildParameters: buildParameters,
            customOutputStream: outputStream,
            customLogLevel: logLevel
        )

        // Run the build. This doesn't return until the build is complete.
        let success = buildSystem.buildIgnoringError(subset: buildSubset)

        // Create and return the build result record based on what the delegate collected and what's in the build plan.
        let builtProducts = try buildSystem.buildPlan.buildProducts.filter {
            switch subset {
            case .all(let includingTests):
                return includingTests ? true : $0.product.type != .test
            case .product(let name):
                return $0.product.name == name
            case .target(let name):
                return $0.product.name == name
            }
        }
        let builtArtifacts: [PluginInvocationBuildResult.BuiltArtifact] = try builtProducts.compactMap {
            switch $0.product.type {
            case .library(let kind):
                return try .init(
                    path: $0.binaryPath.pathString,
                    kind: (kind == .dynamic) ? .dynamicLibrary : .staticLibrary
                )
            case .executable:
                return try .init(path: $0.binaryPath.pathString, kind: .executable)
            default:
                return nil
            }
        }
        return PluginInvocationBuildResult(
            succeeded: success,
            logText: outputStream.bytes.cString,
            builtArtifacts: builtArtifacts)
    }

    func pluginRequestedTestOperation(
        subset: PluginInvocationTestSubset,
        parameters: PluginInvocationTestParameters,
        completion: @escaping (Result<PluginInvocationTestResult, Error>
        ) -> Void) {
        // Run the test in the background and call the completion handler when done.
        DispatchQueue.sharedConcurrent.async {
            completion(Result {
                return try self.performTestsForPlugin(subset: subset, parameters: parameters)
            })
        }
    }

    func performTestsForPlugin(
        subset: PluginInvocationTestSubset,
        parameters: PluginInvocationTestParameters
    ) throws -> PluginInvocationTestResult {
        // Build the tests. Ideally we should only build those that match the subset, but we don't have a way to know
        // which ones they are until we've built them and can examine the binaries.
        let toolchain = try swiftTool.getTargetToolchain()
        var buildParameters = try swiftTool.buildParameters()
        buildParameters.enableTestability = true
        buildParameters.enableCodeCoverage = parameters.enableCodeCoverage
        let buildSystem = try swiftTool.createBuildSystem(customBuildParameters: buildParameters)
        try buildSystem.build(subset: .allIncludingTests)

        // Clean out the code coverage directory that may contain stale `profraw` files from a previous run of
        // the code coverage tool.
        if parameters.enableCodeCoverage {
            try swiftTool.fileSystem.removeFileTree(buildParameters.codeCovPath)
        }

        // Construct the environment we'll pass down to the tests.
        let testEnvironment = try TestingSupport.constructTestEnvironment(
            toolchain: toolchain,
            buildParameters: buildParameters,
            sanitizers: swiftTool.options.build.sanitizers
        )

        // Iterate over the tests and run those that match the filter.
        var testTargetResults: [PluginInvocationTestResult.TestTarget] = []
        var numFailedTests = 0
        for testProduct in buildSystem.builtTestProducts {
            // Get the test suites in the bundle. Each is just a container for test cases.
            let testSuites = try TestingSupport.getTestSuites(
                fromTestAt: testProduct.bundlePath,
                swiftTool: swiftTool,
                enableCodeCoverage: parameters.enableCodeCoverage,
                sanitizers: swiftTool.options.build.sanitizers
            )
            for testSuite in testSuites {
                // Each test suite is just a container for test cases (confusingly called "tests",
                // though they are test cases).
                for testCase in testSuite.tests {
                    // Each test case corresponds to a combination of target and a XCTestCase, and is
                    // a collection of tests that can actually be run.
                    var testResults: [PluginInvocationTestResult.TestTarget.TestCase.Test] = []
                    for testName in testCase.tests {
                        // Check if we should filter out this test.
                        let testSpecifier = testCase.name + "/" + testName
                        if case .filtered(let regexes) = subset {
                            guard regexes.contains(
                                where: { testSpecifier.range(of: $0, options: .regularExpression) != nil }
                            ) else {
                                continue
                            }
                        }

                        // Configure a test runner.
                        let testRunner = TestRunner(
                            bundlePaths: [testProduct.bundlePath],
                            xctestArg: testSpecifier,
                            cancellator: swiftTool.cancellator,
                            toolchain: toolchain,
                            testEnv: testEnvironment,
                            observabilityScope: swiftTool.observabilityScope)

                        // Run the test — for now we run the sequentially so we can capture accurate timing results.
                        let startTime = DispatchTime.now()
                        let success = testRunner.test(outputHandler: { _ in }) // this drops the tests output
                        let duration = Double(startTime.distance(to: .now()).milliseconds() ?? 0) / 1000.0
                        numFailedTests += success ? 0 : 1
                        testResults.append(
                            .init(name: testName, result: success ? .succeeded : .failed, duration: duration)
                        )
                    }

                    // Don't add any results if we didn't run any tests.
                    if testResults.isEmpty { continue }

                    // Otherwise we either create a new create a new target result or add to the previous one,
                    // depending on whether the target name is the same.
                    let testTargetName = testCase.name.prefix(while: { $0 != "." })
                    if let lastTestTargetName = testTargetResults.last?.name, testTargetName == lastTestTargetName {
                        // Same as last one, just extend its list of cases. We know we have a last one at this point.
                        testTargetResults[testTargetResults.count-1].testCases.append(
                            .init(name: testCase.name, tests: testResults)
                        )
                    }
                    else {
                        // Not the same, so start a new target result.
                        testTargetResults.append(
                            .init(
                                name: String(testTargetName),
                                testCases: [.init(name: testCase.name, tests: testResults)]
                            )
                        )
                    }
                }
            }
        }

        // Deal with code coverage, if enabled.
        let codeCoverageDataFile: AbsolutePath?
        if parameters.enableCodeCoverage {
            // Use `llvm-prof` to merge all the `.profraw` files into a single `.profdata` file.
            let mergedCovFile = buildParameters.codeCovDataFile
            let codeCovFileNames = try swiftTool.fileSystem.getDirectoryContents(buildParameters.codeCovPath)
            var llvmProfCommand = [try toolchain.getLLVMProf().pathString]
            llvmProfCommand += ["merge", "-sparse"]
            for fileName in codeCovFileNames where fileName.hasSuffix(".profraw") {
                let filePath = buildParameters.codeCovPath.appending(component: fileName)
                llvmProfCommand.append(filePath.pathString)
            }
            llvmProfCommand += ["-o", mergedCovFile.pathString]
            try TSCBasic.Process.checkNonZeroExit(arguments: llvmProfCommand)

            // Use `llvm-cov` to export the merged `.profdata` file contents in JSON form.
            var llvmCovCommand = [try toolchain.getLLVMCov().pathString]
            llvmCovCommand += ["export", "-instr-profile=\(mergedCovFile.pathString)"]
            for product in buildSystem.builtTestProducts {
                llvmCovCommand.append("-object")
                llvmCovCommand.append(product.binaryPath.pathString)
            }
            // We get the output on stdout, and have to write it to a JSON ourselves.
            let jsonOutput = try TSCBasic.Process.checkNonZeroExit(arguments: llvmCovCommand)
            let jsonCovFile = buildParameters.codeCovDataFile.parentDirectory.appending(
                component: buildParameters.codeCovDataFile.basenameWithoutExt + ".json"
            )
            try swiftTool.fileSystem.writeFileContents(jsonCovFile, string: jsonOutput)

            // Return the path of the exported code coverage data file.
            codeCoverageDataFile = jsonCovFile
        }
        else {
            codeCoverageDataFile = nil
        }

        // Return the results to the plugin. We only consider the test run a success if no test failed.
        return PluginInvocationTestResult(
            succeeded: (numFailedTests == 0),
            testTargets: testTargetResults,
            codeCoverageDataFile: codeCoverageDataFile?.pathString)
    }

    func pluginRequestedSymbolGraph(
        forTarget targetName: String,
        options: PluginInvocationSymbolGraphOptions,
        completion: @escaping (Result<PluginInvocationSymbolGraphResult, Error>) -> Void
    ) {
        // Extract the symbol graph in the background and call the completion handler when done.
        DispatchQueue.sharedConcurrent.async {
            completion(Result {
                return try self.createSymbolGraphForPlugin(forTarget: targetName, options: options)
            })
        }
    }

    private func createSymbolGraphForPlugin(
        forTarget targetName: String,
        options: PluginInvocationSymbolGraphOptions
    ) throws -> PluginInvocationSymbolGraphResult {
        // Current implementation uses `SymbolGraphExtract()`, but in the future we should emit the symbol graph
        // while building.

        // Create a build system for building the target., skipping the the cache because we need the build plan.
        let buildSystem = try swiftTool.createBuildSystem(explicitBuildSystem: .native, cacheBuildManifest: false)

        // Find the target in the build operation's package graph; it's an error if we don't find it.
        let packageGraph = try buildSystem.getPackageGraph()
        guard let target = packageGraph.allTargets.first(where: { $0.name == targetName }) else {
            throw StringError("could not find a target named “\(targetName)”")
        }

        // Build the target, if needed.
        try buildSystem.build(subset: .target(target.name))

        // Configure the symbol graph extractor.
        var symbolGraphExtractor = try SymbolGraphExtract(
            fileSystem: swiftTool.fileSystem,
            tool: swiftTool.getTargetToolchain().getSymbolGraphExtract(),
            observabilityScope: swiftTool.observabilityScope
        )
        symbolGraphExtractor.skipSynthesizedMembers = !options.includeSynthesized
        switch options.minimumAccessLevel {
        case .private:
            symbolGraphExtractor.minimumAccessLevel = .private
        case .fileprivate:
            symbolGraphExtractor.minimumAccessLevel = .fileprivate
        case .internal:
            symbolGraphExtractor.minimumAccessLevel = .internal
        case .public:
            symbolGraphExtractor.minimumAccessLevel = .public
        case .open:
            symbolGraphExtractor.minimumAccessLevel = .open
        }
        symbolGraphExtractor.skipInheritedDocs = true
        symbolGraphExtractor.includeSPISymbols = options.includeSPI
        symbolGraphExtractor.emitExtensionBlockSymbols = options.emitExtensionBlocks

        // Determine the output directory, and remove any old version if it already exists.
        guard let package = packageGraph.package(for: target) else {
            throw StringError("could not determine the package for target “\(target.name)”")
        }
        let outputDir = try buildSystem.buildPlan.buildParameters.dataPath.appending(
            components: "extracted-symbols",
            package.identity.description,
            target.name
        )
        try swiftTool.fileSystem.removeFileTree(outputDir)

        // Run the symbol graph extractor on the target.
        try symbolGraphExtractor.extractSymbolGraph(
            target: target,
            buildPlan: try buildSystem.buildPlan,
            outputRedirection: .collect,
            outputDirectory: outputDir,
            verboseOutput: self.swiftTool.logLevel <= .info
        )

        // Return the results to the plugin.
        return PluginInvocationSymbolGraphResult(directoryPath: outputDir.pathString)
    }
}

extension BuildSystem {
    fileprivate func buildIgnoringError(subset: BuildSubset) -> Bool {
        do {
            try self.build(subset: subset)
            return true
        } catch {
            return false
        }
    }
}
