// Ghidra headless post-script: decompiles every function of the current program into
// <outDir>/<program>.c (one block per function, sorted by address) and dumps defined strings
// into <outDir>/<program>.strings.txt.
// Usage: analyzeHeadless <proj> <name> -import <bin> -postScript DecompileAll.java <outDir>
//@category MRCarve

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

import java.io.File;
import java.io.PrintWriter;

public class DecompileAll extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        File outDir = new File(args.length > 0 ? args[0] : ".");
        outDir.mkdirs();
        String name = currentProgram.getName();

        DecompInterface ifc = new DecompInterface();
        DecompileOptions opts = new DecompileOptions();
        ifc.setOptions(opts);
        ifc.toggleCCode(true);
        ifc.toggleSyntaxTree(false);
        ifc.openProgram(currentProgram);

        int count = 0, failed = 0;
        try (PrintWriter out = new PrintWriter(new File(outDir, name + ".c"), "UTF-8")) {
            FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
            while (it.hasNext() && !monitor.isCancelled()) {
                Function f = it.next();
                if (f.isExternal() || f.isThunk()) continue;
                out.println("// ==== " + f.getEntryPoint() + "  " + f.getName(true) + "  [" + f.getSignature().getPrototypeString() + "]");
                DecompileResults r = ifc.decompileFunction(f, 120, monitor);
                if (r != null && r.decompileCompleted() && r.getDecompiledFunction() != null) {
                    out.println(r.getDecompiledFunction().getC());
                } else {
                    failed++;
                    out.println("/* decompile failed: " + (r == null ? "null" : r.getErrorMessage()) + " */\n");
                }
                count++;
            }
        }
        ifc.dispose();

        try (PrintWriter out = new PrintWriter(new File(outDir, name + ".strings.txt"), "UTF-8")) {
            DataIterator di = currentProgram.getListing().getDefinedData(true);
            while (di.hasNext()) {
                Data d = di.next();
                if (!d.hasStringValue()) continue;
                StringDataInstance s = StringDataInstance.getStringDataInstance(d);
                String v = s.getStringValue();
                if (v != null && v.length() >= 3) out.println(d.getAddress() + "\t" + v.replace("\n", "\\n"));
            }
        }
        println("DecompileAll: " + name + " functions=" + count + " failed=" + failed);
    }
}
