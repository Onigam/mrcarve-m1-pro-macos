import Foundation

// Each suite adds its tests here.
CoreTypesTests.register()
ModelProjectTests.register(); ModelGeometryTests.register(); ModelJobCompilerTests.register()
EngineGeometryTests.register(); EngineFlattenTests.register(); EngineTextTests.register(); EngineHatchTests.register()
EngineOptimizerTests.register(); EngineImportTests.register(); EngineRasterTests.register(); EngineConfigTests.register()
ProtocolTests.register(); ProtocolLegacyTests.register()

exit(runRegisteredTests(filter: CommandLine.arguments.dropFirst().first))
