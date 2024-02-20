(* Z3 oracle solver returning a model when Z3 reports SAT.
 *
 * Some code in this file has been adapted from HolSmt and are under copyright:
 * Copyright (c) 2009-2012 Tjark Weber. All rights reserved.
 *)

structure Z3_SAT_modelLib :> Z3_SAT_modelLib =
struct

  type model = (string * Term.term) list;

  local

  val ERR = Feedback.mk_HOL_ERR "Z3_with_modelLib"

  datatype result = SAT of model option  (* model *)
                  | UNSAT of Thm.thm option  (* assumptions |- conclusion *)
                  | UNKNOWN of string option  (* reason for failure *)

  (* Copied from HolSmt to change the return type *)
  (* calls 'pre' (which is supposed to translate a HOL goal into a list of
     strings that the SMT solver will understand); writes these strings into a
     file; appends the names of input and output files to 'cmd_stem' before
     executing it as a system command; calls 'post' (which is supposed to parse
     the output file generated by the SMT solver); deletes input and output
     file (unless '!trace' = 4); emits messages according to '!trace' *)
  fun make_solver (pre : Abbrev.goal -> 'a * string list)
                  (cmd_stem : string)
                  (post : 'a -> string -> result) : Abbrev.goal -> result =
  fn goal =>
  let
    (* call 'pre goal' to generate SMT solver input *)
    val (x, inputs) = pre goal
    val infile = FileSys.tmpName ()
    val _ = HolBA_Library.write_strings_to_file infile inputs
    val outfile = FileSys.tmpName ()
    val cmd = cmd_stem ^ infile ^ " > " ^ outfile
    (* the actual system call to the SMT solver *)
    val _ = if !HolBA_Library.trace > 1 then
        Feedback.HOL_MESG ("Z3_with_modelLib: calling external command '" ^ cmd ^ "'")
      else ()
    val _ = Systeml.system_ps cmd
    (* call 'post' to determine the result *)
    val result = post x outfile
    val _ = if !HolBA_Library.trace > 1 then
        Feedback.HOL_MESG ("Z3_with_modelLib: Z3 reports term to be '" ^
          (case result of
             SAT NONE => "satisfiable' (no model given)"
           | SAT (SOME _) => "satisfiable' (model given)"
           | UNSAT NONE => "unsatisfiable' (no proof given)"
           | UNSAT (SOME thm) =>
             if !HolBA_Library.trace > 2 then
               "unsatisfiable' (theorem: " ^ Hol_pp.thm_to_string thm ^ ")"
             else
               "unsatisfiable' (proof checked)"
           | UNKNOWN NONE => "unknown' (no reason given)"
           | UNKNOWN (SOME reason) => "unknown' (reason: " ^ reason ^ ")"))
      else ()
    (* if the SMT solver returned a theorem 'thm', then this should be of the
       form "A' |- g" with A' \subseteq A, where (A, g) is the input goal *)
    val _ = if !HolBA_Library.trace > 0 then
        case result of
          UNSAT (SOME thm) =>
            let
              val (As, g) = goal
              val As = HOLset.fromList Term.compare As
            in
              if not (HOLset.isSubset (Thm.hypset thm, As)) then
                Feedback.HOL_WARNING "Z3_with_model" "make_solver"
                  "theorem contains additional hyp(s)"
              else ();
              if not (Term.aconv (Thm.concl thm) g) then
                Feedback.HOL_WARNING "Z3_with_model" "make_solver"
                  "conclusion of theorem does not match goal"
              else ()
            end
        | _ =>
          ()
      else ()
    (* delete all temporary files *)
    val _ = if !HolBA_Library.trace < 4 then
        List.app (fn path => OS.FileSys.remove path handle SysErr _ => ())
          [infile, outfile]
      else ()
  in
    result
  end

  (* returns SAT if Z3 reported "sat", UNSAT if Z3 reported "unsat" *)
  fun is_sat_stream instream =
    case Option.map (String.tokens Char.isSpace) (TextIO.inputLine instream) of
      NONE => raise ERR "is_sat_stream" "The Z3 wrapper didn't print anything on stdout"
    | SOME ["unknown"] => UNKNOWN NONE
    | SOME ["unsat"] => UNSAT NONE
    | SOME ["sat"] =>
      let
        fun parse_tm_list instream acc =
          let
            val line1 = TextIO.inputLine instream;
            val line2 = TextIO.inputLine instream;
            val name = Option.map (fn line => String.substring (line, 0, String.size (line) - 1)) line1;
            val term = Option.map (fn line => Parse.Term [QUOTE line]) line2;
          in
            case (name, term) of
                (SOME name, SOME term) => parse_tm_list instream ((name, term)::acc)
              | _ => acc
          end
        val model = parse_tm_list instream [];
      in
        if List.null model then
          SAT NONE
        else
          SAT (SOME model)
      end
    | _ => raise ERR "is_sat_stream" "Malformed Z3 output: first line not recognized"

  fun is_sat_file path =
    let
      val instream = TextIO.openIn path
    in
      is_sat_stream instream
        before TextIO.closeIn instream
    end

  fun mk_Z3_fun name pre cmd_stem post goal =
    case OS.Process.getEnv "HOL4_Z3_WRAPPED_EXECUTABLE" of
      SOME file =>
        make_solver pre (file ^ (cmd_stem ^ " ")) post goal
    | NONE =>
        raise ERR name
          "Z3_with_model not configured: set the HOL4_Z3_WRAPPED_EXECUTABLE environment variable to point to the Python Z3 wrapper."

  (* Z3 (Linux/Unix), SMT-LIB file format, no proofs, custom result datatype *)
  val Z3_ORACLE_SOLVE_GOAL =
    mk_Z3_fun "Z3_ORACLE_SOLVE_GOAL"
      (fn goal =>
        let
          val (_, strings) = HolBA_SmtLib.goal_to_SmtLib_unnegated goal
        in
          ((), strings)
        end)
      ""
      (Lib.K is_sat_file)

  (* Commented out since as-is the conclusion of the produced theorem is
   * different than the given term.
  fun Z3_ORACLE_SOLVE term =
    let
      val ERR = ERR "Z3_ORACLE_SOLVE"
      val solver = Z3_ORACLE_SOLVE_GOAL
      val goal = ([], term)
      val (simplified_goal, _) = HolBA_SolverSpec.simplify (HolBA_SmtLib.SIMP_TAC false) goal
      val negated_goal = ([], boolSyntax.mk_neg (snd simplified_goal))
    in
      case solver goal of
          UNSAT NONE => UNSAT (SOME (Thm.mk_oracle_thm "Z3_with_modelLib" negated_goal))
        | otherwise => otherwise
    end*)

  in

  fun is_configured () =
    Option.isSome (OS.Process.getEnv "HOL4_Z3_WRAPPED_EXECUTABLE")

  fun Z3_GET_SAT_MODEL term =
    let
      val ERR = ERR "Z3_GET_SAT_MODEL"
      val goal = ([], term)
      val (simplified_goal, _) = HolBA_SolverSpec.simplify (HolBA_SmtLib.SIMP_TAC false) goal

      val _ =
        if !HolBA_Library.trace > 4 then
        let
          val _ = print "simplified goal >>>\n";
          open HolKernel boolLib liteLib simpLib Parse bossLib;
          val (sg_tl, sg_t) = simplified_goal;
          val _ = print ((Int.toString (List.length sg_tl)) ^ "\n");
          val _ = print_term sg_t;
          val _ = List.map print_term sg_tl;
          val _ = print "<<< simplified goal done\n";
        in () end else ();

      val result = Z3_ORACLE_SOLVE_GOAL simplified_goal
    in
      case result of
          SAT (SOME model) => model
        | SAT NONE => raise ERR "Z3 reports term to be satisfiable, but didn't produce a model."
        | UNSAT _ => raise ERR "Z3 reports term to be unsatisfiable."
        | UNKNOWN _ => raise ERR "Z3 reports term to be unknown."
    end

  end (* local *)

end (* Z3_SAT_modelLib *)
