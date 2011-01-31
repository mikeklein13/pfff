(*s: builtins_php.ml *)
(*s: Facebook copyright *)
(* Yoann Padioleau
 * 
 * Copyright (C) 2009-2010 Facebook
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 * 
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
(*e: Facebook copyright *)

open Common 

open Ast_php

module Flag = Flag_analyze_php
module Ast = Ast_php

module V = Visitor_php

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)

(* 
 * As opposed to OCaml or C++ or Java or most programming languages, 
 * there is no source code files where PHP builtin functions
 * and their types are declared. They are defined in the PHP manual 
 * and somewhere in the source code of Zend.
 * In OCaml most library functions are written in OCaml itself or are specified
 * via an 'external' declaration as in:
 * 
 *   external (=) : 'a -> 'a -> bool = "%equal"
 * 
 * This is very convenient for certain tasks such as code browsing where
 * many functions would be seen as 'undefined' otherwise, or for 
 * the type inference  where we have info about the basic functions. 
 * 
 * Unfortunately, this is not the case for PHP. Fortunately the
 * good guys from HPHP have spent some time to specify in a IDL form 
 * the interface of many of those builtin PHP functions (including the 
 * one in some popular PHP extensions). They used it to 
 * generate C++ header files, but we can abuse it to instead generate
 * PHP "header" files that our tool can understand.
 * 
 * Moreover the PHP manual is stored in XML files and can also
 * be automatically processed to extract the names and types
 * of the builtin functions, classes, and constants.
 *)


(*****************************************************************************)
(* HPHP IDL *)
(*****************************************************************************)

(* 
 * Here is for instance the content of one such IDL file,
 * hphp/src/idl/math.idl.php:
 * 
 * DefineFunction(
 *   array(
 *     'name'   => "round",
 *     'desc'   => "Returns the rounded value ...",
 *     'flags'  =>  HasDocComment,
 *     'return' => array(
 *       'type'   => Double,
 *       'desc'   => "The rounded value",
 *     ),
 *     'args'   => array(
 *       array(
 *         'name'   => "val",
 *         'type'   => Variant,
 *         'desc'   => "The value to round",
 *       ),
 *       array(
 *         'name'   => "precision",
 *         'type'   => Int64,
 *         'value'  => "0",
 *         'desc'   => "The optional number of decimal digits to round to.",
 *       ),
 *     ),
 *   ));
 * 
 * (It's used to be just:
 *      f('round',   Double,  array('val' => Variant,
 *                       'precision' => array(Int64, '0')));
 * )
 * 
 * which defines the interface for the 'round' builtin math function.
 * In the manual at http://us3.php.net/round is is defined a:
 * 
 *     float round  ( float $val  [, int $precision = 0] )
 * 
 * So the only job of this module is to generate from the IDL file 
 * some PHP code like:
 * 
 *    function round($val, $precision = 0) {
 *       // THIS IS AUTOGENERATED BY builtins_php.ml
 *    }
 * 
 * or even better:
 * 
 *    function round(Variant $val, int $precision = 0) double {
 *       // THIS IS AUTOGENERATED BY builtins_php.ml
 *    }
 * 
 * history: 
 *  I was originally generating the files by analyzing the IDL
 *  files via pfff and pattern match the different cases.
 *  As the IDL got more complicated, it was far simpler
 *  to just define in PHP a DefineFunction() function that would
 *  do the appropriate things, just like what they do for generating
 *  C++ headers.
 * 
 * alternatives:
 *  - could analyze Zend source code ? Do they have something similar ?
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

(* Not used anymore, but it can be useful to have some formal representations
 * of the HPHP idl files.
 *)

(* see hphp/src/idl/base.php. generated mostly via macro *)
type idl_type = 
  | Boolean

  (* maybe not used *)
  | Byte
  | Int16

  | Int32
  | Int64
  | Double
  | String

  | Int64Vec
  | StringVec
  | VariantVec

  | Int64Map
  | StringMap
  | VariantMap

  | Object
  | Resource

  | Variant

  | Numeric
  | Primitive
  | PlusOperand
  | Sequence

  | Any

  (* Added by me *)
  | NULL
  | Void


type idl_param = {
  p_name: string;
  p_type: idl_type;
  p_isref: bool;
  p_default_val: string option;
}

type idl_entry = 
  | Global of string * idl_type
  | Function of 
      string * idl_type * idl_param list * bool (* has variable arguments *)
  (* todo: Class, Constant, etc *)

let special_comment = 
  "// THIS IS AUTOGENERATED BY builtins_php.ml\n"
let builtins_do_not_give_decl = 
  ["die";"eval";"exit";"__halt_compiler";"echo"; "print"]

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

let idl_type__str_conv = [
  Boolean     , "Boolean";
  Byte        , "Byte";
  Int16       , "Int16";
  Int32       , "Int32";
  Int64       , "Int64";
  Double      , "Double";
  String      , "String";
  Int64Vec    , "Int64Vec";
  StringVec   , "StringVec";
  VariantVec  , "VariantVec";
  Int64Map    , "Int64Map";
  StringMap   , "StringMap";
  VariantMap  , "VariantMap";
  Object      , "Object";
  Resource    , "Resource";
  Variant     , "Variant";
  Numeric     , "Numeric";
  Primitive   , "Primitive";
  PlusOperand , "PlusOperand";
  Sequence    , "Sequence";
  Any         , "Any";

  NULL        ,  "NULL";
  NULL        ,  "Null";
]

let (idl_type_of_string, str_of_idl_type) = 
 Common.mk_str_func_of_assoc_conv idl_type__str_conv

let idl_type_of_string (s, info) =
    try idl_type_of_string s
    with Not_found ->
      let pinfo = Ast.parse_info_of_info info in
      pr2 (Parse_info.error_message_info pinfo);
      failwith ("not a idl type: " ^ s)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(*****************************************************************************)
(* Main entry point *)
(*****************************************************************************)

(* Generating stdlib from idl files *)
let generate_php_stdlib ~src ~phpmanual_dir ~dest = 
  let files = Lib_parsing_php.find_php_files_of_dir_or_files [src] in

  (* todo: put back this feature:
   * let phpdoc_finder = 
   *   Phpmanual_xml.build_doc_function_finder phpmanual_dir in
   *)

  if not (Common.command2_y_or_no("rm -rf " ^ dest))
  then failwith "ok we stop";
  Common.command2("mkdir -p " ^ dest);

  files +> List.iter (fun file -> 
    pr2 (spf "processing: %s" file);

    if not (file =~ ".*\\.idl.php")
    then pr2 (spf "SKIPPING: %s, files does not end in .idl.php" file)
    else begin
      let base = Filename.basename file in
      let target = Filename.concat dest ("builtins_" ^ base) in
      let cmd = spf " php -f %s/scripts/gen_builtins_php.php %s > %s"
        (Sys.getenv "PFFF_HOME") file target in
      Common.command2 cmd;
    end
  );
  ()

(*****************************************************************************)
(* Actions *)
(*****************************************************************************)

let actions () = [
  (* e.g. 
   * ./pfff_misc -generate_php_stdlib tests/idl/ 
   *    ~/software-src/phpdoc-svn/reference/   data/php_stdlib2
   * to test do:
   * ./pfff_misc -generate_php_stdlib tests/idl/array.idl.php
   *   ~/software-src/phpdoc-svn/reference/array/   data/php_stdlib2
   *)
  "-generate_php_stdlib", " <src_idl> <src_phpmanual> <dest>",
  Common.mk_action_3_arg (fun src phpmanual_dir dest ->
    generate_php_stdlib ~src ~phpmanual_dir ~dest);
]
(*e: builtins_php.ml *)
