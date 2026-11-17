(* SPDX-License-Identifier: BSD-2-Clause
   Copyright (c) 2026 Stanislav Sedov <stas@deglitch.com> *)

type stop = Object | Assembly | Syntax_check

type dependency =
  | Write_dependencies
  | Dependency_file
  | Dependency_target
  | Dependency_detail

type typec_option = Cc | Print_target | Emit_c | Stats

type role =
  | Preprocess
  | Dependency of dependency
  | Link
  | Common
  | Architecture
  | Dialect
  | Keywords of Typec_syntax.Keyword_set.dialect
  | Output
  | Language
  | Stop of stop
  | Refused of string
  | Typec of typec_option

type t = { role : role; separate_values : int; joined_value : string }

(* How an option is spelled with its values, as GCC and Clang read it. *)
type form =
  | Flag  (** exactly the spelling, without a value *)
  | Separate of int  (** exactly the spelling, then that many values *)
  | Joined  (** the spelling with its value appended *)
  | Joined_or_separate
      (** the spelling with its value appended, or the spelling alone
          and then the value *)
  | Joined_and_separate
      (** the spelling with a value appended, then one more value *)

type entry = { spelling : string; form : form; role : role }

let entries role form spellings =
  List.map (fun spelling -> { spelling; form; role }) spellings

(* The long options of GCC and Clang take their value after "=" or as
   the next argument. *)
let long_entries role spellings =
  entries role (Separate 1) spellings
  @ entries role Joined (List.map (fun spelling -> spelling ^ "=") spellings)

let stops_at_preprocessing =
  "it stops after preprocessing; --emit-c writes the C of a .tc input"

let changes_preprocessed_text =
  "the preprocessed text must keep its line markers and nothing else"

let keeps_intermediate_files =
  "typec keeps no intermediate files; --emit-c writes the C"

let short_enums =
  "it gives an enumeration the narrowest integer type that holds its \
   values, which typec's target model does not read"

let unsigned_bit_fields =
  "GCC makes every bit-field declared without signed or unsigned \
   unsigned, which typec's target model does not read"

let float_constants =
  "GCC makes an unsuffixed floating constant float, which typec's \
   target model does not read"

(* Design 10.3 and 13.2. *)
let pack_struct =
  "under it GCC ignores each '#pragma pack' that typec writes around an \
   instance of a generic, and warns of it; -fpack-struct=n passes"

(* The options of typec, and those of the C compilers that typec
   supports (Target.minimum_major_version) up to GCC 16 and Clang 21,
   Apple's included, that the pipeline must tell apart or that take a
   separate value; the options of GCC's other front ends are left out.
   A Common option needs an entry only when it takes a separate value:
   unknown options are Common already. *)
let table =
  List.concat
    [
      entries (Typec Cc) Joined [ "--cc=" ];
      entries (Typec Print_target) Flag [ "--print-target" ];
      entries (Typec Emit_c) Flag [ "--emit-c" ];
      entries (Typec Stats) Flag [ "--stats" ];
      (* What the command line makes and of what. *)
      entries Output Joined_or_separate [ "-o" ];
      long_entries Output [ "--output" ];
      entries Language Joined_or_separate [ "-x" ];
      long_entries Language [ "--language" ];
      entries (Stop Object) Flag [ "-c" ];
      entries (Stop Assembly) Flag [ "-S" ];
      entries (Stop Syntax_check) Flag [ "-fsyntax-only" ];
      entries Dialect Joined [ "-std=" ];
      long_entries Dialect [ "--std" ];
      entries (Keywords Gnu) Flag [ "-fasm" ];
      entries (Keywords Iso) Flag [ "-fno-asm" ];
      (* Dependencies. *)
      entries (Dependency Write_dependencies) Flag [ "-MD"; "-MMD" ];
      entries (Dependency Dependency_file) Joined_or_separate [ "-MF" ];
      entries (Dependency Dependency_target) Joined_or_separate
        [ "-MT"; "-MQ" ];
      entries (Dependency Dependency_detail) Flag [ "-MP"; "-MG"; "-MV" ];
      entries (Dependency Dependency_detail) Joined_or_separate [ "-MJ" ];
      (* Options that the pipeline cannot follow. *)
      entries (Refused stops_at_preprocessing) Flag [ "-E"; "-M"; "-MM" ];
      entries (Refused changes_preprocessed_text) Flag
        [
          "-P"; "-C"; "-CC"; "-fuse-line-directives"; "-dD"; "-dM"; "-dN";
          "-dI"; "-dU"; "-traditional"; "-traditional-cpp";
          "-fdirectives-only"; "-fpreprocessed";
        ];
      entries (Refused keeps_intermediate_files) Flag [ "-save-temps" ];
      entries (Refused keeps_intermediate_files) Joined [ "-save-temps=" ];
      entries (Refused "it prints the commands instead of running them")
        Flag [ "-###" ];
      entries (Refused "it selects C90, and Type-C accepts C11 and C17")
        Flag [ "-ansi" ];
      entries (Refused "typec does not read the inputs after it") Flag
        [ "--" ];
      (* Options that change a type of C but no macro the target model
         reads, so the model would disagree with the backend, or that
         make the backend ignore what typec writes. Each is refused
         wherever it stands, even before the option that undoes it.
         Options that change a macro the model reads, such as
         -fshort-wchar, reach it through the target query, and the front
         end computes no layout, so the other options of layout, such as
         -fpack-struct=n, pass. *)
      entries (Refused short_enums) Flag [ "-fshort-enums" ];
      entries (Refused unsigned_bit_fields) Flag
        [ "-funsigned-bitfields"; "-fno-signed-bitfields" ];
      entries (Refused float_constants) Flag
        [ "-fsingle-precision-constant" ];
      entries (Refused pack_struct) Flag [ "-fpack-struct" ];
      (* Preprocessing. *)
      entries Preprocess Joined_or_separate
        [
          "-A"; "-D"; "-U"; "-I"; "-idirafter"; "-iframework";
          "-iframeworkwithsysroot"; "-imacros"; "-include"; "-iprefix";
          "-iquote"; "-isystem"; "-isystem-after"; "-iwithprefix";
          "-iwithprefixbefore"; "-iwithsysroot"; "-cxx-isystem";
          "-stdlib++-isystem"; "-imultilib"; "-imultiarch";
        ];
      entries Preprocess (Separate 1)
        [
          "-include-pch"; "-Xpreprocessor"; "-dependency-file";
          "-dependency-dot"; "-module-dependency-dir";
          "-fexperimental-openacc-macro-override";
        ];
      long_entries Preprocess
        [
          "--assert"; "--define-macro"; "--undefine-macro"; "--include";
          "--imacros"; "--include-directory"; "--include-directory-after";
          "--include-prefix"; "--include-with-prefix";
          "--include-with-prefix-after"; "--include-with-prefix-before";
          "--embed-directory"; "--system-header-prefix";
          "--no-system-header-prefix";
        ];
      entries Preprocess Joined [ "-Wp," ];
      entries Preprocess Flag [ "-nostdinc"; "-undef"; "-H" ];
      (* The source's encoding: only the step that reads the source
         decodes it, and GCC writes UTF-8 for -E, which the compile step
         reads by default whatever the locale. *)
      entries Preprocess Joined [ "-finput-charset=" ];
      (* Linking. *)
      entries Link Joined_or_separate [ "-l"; "-L"; "-T" ];
      entries Link (Separate 1)
        [
          "-alias_list"; "-allowable_client"; "-arch_only"; "-assert"; "-b";
          "-bundle_loader"; "-client_name"; "-compatibility_version";
          "-current_version"; "-defsym"; "-dylib_file";
          "-dylinker_install_name"; "-e"; "-exported_symbols_list";
          "-filelist"; "-force_load"; "-framework"; "-h"; "-image_base";
          "-init"; "-install_name"; "-lazy_framework"; "-lazy_library";
          "-multiply_defined"; "-multiply_defined_unused"; "-pagezero_size";
          "-R"; "-read_only_relocs"; "-reexport_framework";
          "-reexport_library"; "-rpath"; "-rpath-link"; "-seg1addr";
          "-seg_addr_table"; "-seg_addr_table_filename";
          "-segs_read_only_addr"; "-segs_read_write_addr"; "-soname";
          "-sub_library"; "-sub_umbrella"; "-Tbss"; "-Tdata"; "-Ttext"; "-u";
          "-umbrella"; "-undefined"; "-unexported_symbols_list";
          "-weak_framework"; "-weak_library"; "-weak_reference_mismatches";
          "-Xlinker"; "-Xstatic-lib-tool"; "-z"; "-Zlinker-input";
        ];
      entries Link (Separate 2) [ "-sectobjectsymbols"; "-segaddr" ];
      entries Link (Separate 3)
        [ "-sectalign"; "-sectcreate"; "-sectorder"; "-segcreate"; "-segprot" ];
      long_entries Link
        [
          "--library-directory"; "--for-linker"; "--force-link"; "--entry";
          "--dyld-prefix"; "--rtlib";
        ];
      entries Link Joined [ "-Wl,"; "-fuse-ld="; "--ld-path=" ];
      entries Link Joined_and_separate [ "-Xoffload-linker" ];
      (* -object would otherwise read as -o with the value "bject". *)
      entries Link Flag
        [
          "-object"; "-static"; "-shared"; "-rdynamic"; "-pie"; "-no-pie";
          "-nostdlib"; "-nostartfiles"; "-nodefaultlibs"; "-nolibc";
          "-static-libgcc"; "-shared-libgcc"; "-bundle"; "-dynamiclib";
        ];
      (* Every step. *)
      entries Architecture (Separate 1) [ "-arch" ];
      entries Common (Separate 1)
        [
          "-target"; "-target-variant"; "-darwin-target-variant";
          "-darwin-target-variant-triple"; "-B"; "-F"; "-G"; "-V";
          "-isysroot"; "-Xclang"; "-Xclangas"; "-Xassembler"; "-Xanalyzer";
          "-Xcuda-fatbinary"; "-Xcuda-ptxas"; "-Xopenmp-target";
          "-Xarch_device"; "-Xarch_host";
          "-Xmicrosoft-visualc-tools-root";
          "-Xmicrosoft-visualc-tools-version"; "-Xmicrosoft-windows-sdk-root";
          "-Xmicrosoft-windows-sdk-version"; "-Xmicrosoft-windows-sys-root";
          "-mllvm"; "-mmlir"; "-meabi"; "-mthread-model"; "-mtarget-linker";
          "-aux-info"; "-dumpbase"; "-dumpbase-ext"; "-dumpdir"; "-wrapper";
          "-truncate"; "-specs"; "-ivfsoverlay"; "-vfsoverlay";
          "-iapinotes-modules"; "-resource-dir"; "-working-directory";
          "-serialize-diagnostics"; "-gen-cdb-fragment-path"; "-dsym-dir";
          "-index-store-path"; "-index-unit-output-path";
          "-fdepscan-share-identifier"; "-fmodules-user-build-path";
          "-fmodule-implementation-of"; "-fdebug-compilation-dir";
          "-object-file-name"; "-ftrapv-handler"; "-fnew-alignment";
          "-hlsl-entry"; "-ccc-gcc-name"; "-ccc-install-dir";
          "-validator-version"; "/validator-version";
          "--analyzer-output"; "--serialize-diagnostics"; "--vfsoverlay";
          "--dumpbase"; "--dumpbase-ext"; "--dumpdir"; "--output-pch";
          "--machine";
        ];
      entries Common (Separate 2) [ "-fdepscan-prefix-map" ];
      long_entries Common
        [
          "--param"; "--prefix"; "--sysroot"; "--specs"; "--config";
          "--stdlib"; "--cstdlib"; "--dump"; "--for-assembler";
          "--print-file-name"; "--print-prog-name"; "--bootclasspath";
          "--CLASSPATH"; "--classpath"; "--encoding"; "--extdirs"; "--mhwdiv";
          "--output-class-directory"; "--resource";
        ];
      entries Common Joined_and_separate
        [ "-Xarch_"; "-Xopenmp-target="; "-Xoffload-compiler" ];
    ]

(* The response file of GCC and Clang, @FILE, holds more arguments. *)
let response_file =
  { role = Refused "typec does not read the options in a response file";
    separate_values = 0;
    joined_value = "" }

let unknown = { role = Common; separate_values = 0; joined_value = "" }

(* How [entry] reads [argument], if it does. *)
let reading argument entry =
  let exact = argument = entry.spelling in
  let prefixed = String.starts_with ~prefix:entry.spelling argument in
  let option separate_values joined_value =
    Some { role = entry.role; separate_values; joined_value }
  in
  let joined () =
    let length = String.length entry.spelling in
    String.sub argument length (String.length argument - length)
  in
  match entry.form with
  | Flag when exact -> option 0 ""
  | Separate count when exact -> option count ""
  | Joined when prefixed -> option 0 (joined ())
  | Joined_or_separate when exact -> option 1 ""
  | Joined_or_separate when prefixed -> option 0 (joined ())
  | Joined_and_separate when prefixed -> option 1 (joined ())
  | Flag | Separate _ | Joined | Joined_or_separate | Joined_and_separate ->
      None

(* The longest spelling wins, so -MF is not read as -M with a value, and
   an exact match beats every prefix. *)
let classify argument =
  let readings =
    List.filter_map
      (fun entry ->
        reading argument entry
        |> Option.map (fun option -> (String.length entry.spelling, option)))
      table
  in
  let longest_first = List.sort (fun (a, _) (b, _) -> compare b a) readings in
  if String.starts_with ~prefix:"@" argument then response_file
  else
    match longest_first with
    | (_, option) :: _ -> option
    | [] -> unknown
