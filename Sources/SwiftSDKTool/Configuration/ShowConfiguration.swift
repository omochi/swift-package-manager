//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import ArgumentParser
import Basics
import CoreCommands
import PackageModel

struct ShowConfiguration: ConfigurationSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: """
        Prints all configuration properties currently applied to a given destination and run-time triple.
        """
    )

    @OptionGroup(visibility: .hidden)
    var locations: LocationOptions

    @Argument(
        help: """
        An identifier of an already installed destination. Use the `list` subcommand to see all available \
        identifiers.
        """
    )
    var sdkID: String

    @Argument(help: "The run-time triple of the destination to configure.")
    var targetTriple: String

    func run(
        hostTriple: Triple,
        targetTriple: Triple,
        _ destination: SwiftSDK,
        _ configurationStore: SwiftSDKConfigurationStore,
        _ destinationsDirectory: AbsolutePath,
        _ observabilityScope: ObservabilityScope
    ) throws {
        print(destination.pathsConfiguration)
    }
}

extension SwiftSDK.PathsConfiguration: CustomStringConvertible {
    public var description: String {
        """
        sdkRootPath: \(sdkRootPath.configurationString)
        swiftResourcesPath: \(swiftResourcesPath.configurationString)
        swiftStaticResourcesPath: \(swiftStaticResourcesPath.configurationString)
        includeSearchPaths: \(includeSearchPaths.configurationString)
        librarySearchPaths: \(librarySearchPaths.configurationString)
        toolsetPaths: \(toolsetPaths.configurationString)
        """
    }
}

extension Optional where Wrapped == AbsolutePath {
    fileprivate var configurationString: String {
        self?.pathString ?? "not set"
    }
}

extension Optional where Wrapped == [AbsolutePath] {
    fileprivate var configurationString: String {
        self?.map(\.pathString).description ?? "not set"
    }
}
