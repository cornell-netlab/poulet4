Require Import Coq.Bool.Bvector.
Require Import Coq.Lists.List.
Require Import Coq.NArith.BinNatDef.
Require Import Coq.Strings.String.

Require Import Monads.Monad.
Require Import Monads.Option.
Require Import Monads.State.

Require Import Value.
Require Import Environment.
Require Import Syntax.
Require Import Utils.

Open Scope monad.

Definition defaultValue (A: type) : value.
Admitted.

Definition powTwo (w: nat) : N.
Admitted.

Definition of_bvector {w} (bits: Bvector w) : N.
Admitted.

Definition evalLvalue (expr: expression) : env_monad lvalue.
Admitted.

Definition evalMinus (v: value) : option value := 
  match v with
  | ValBit width bits => Some (ValFixedInt width (N.to_nat (N.sub (powTwo width) (of_bvector bits))))
  | ValFixedInt width value => Some (ValFixedInt width (N.to_nat (N.sub (powTwo width) (N.of_nat value))))
  | ValSignedInt n => Some (ValSignedInt (Decimal.opp n))
  | _ => None
  end.

Fixpoint evalExpression (expr: expression) : env_monad value :=
  match expr with
  | BoolExpression value => mret (ValBool value)
  | IntExpression value => mret (ValInt value)
  | StringExpression value => mret (ValString value)
  | ArrayAccess array index =>
    let* index' := evalExpression index in
    let* array' := evalExpression array in
    match (array', index') with
    | (ValArray array'', ValInt index'') => lift_option (List.nth_error array'' index'')
    | _ => state_fail Internal
    end
  | BitStringAccess array hi lo =>
    let* array' := evalExpression array in
    let* hi'    := evalExpression hi in
    let* lo'    := evalExpression lo in
    match (array', hi', lo') with
    | (ValArray array'', ValInt hi'', ValInt lo'') => lift_option (option_map ValArray (list_slice array'' lo'' hi''))
    | _ => state_fail Internal
    end
  | List exprs => liftM ValArray (sequence (List.map evalExpression exprs))
  | Record entries => 
    let actions := List.map (fun x => match x with | MkKeyValue k e => v <- evalExpression e ;; mret (k, v) end) entries in
    liftM ValRecord (sequence actions)
  | UnaryOp op arg => 
    let* inner := evalExpression arg in
    match op with
    | Not => 
      match inner with
      | ValBool b => mret (ValBool (negb b))
      | _ => state_fail Internal
      end
    | BitNot => 
      match inner with
      | ValBit w bits => mret (ValBit w (Bneg w bits))
      | _ => state_fail Internal
      end
    | BitMinus => lift_option (evalMinus inner)
    end
  | _ => mret (ValBool false) (* TODO *)
  end.

Definition evalIsValid (obj: lvalue) : env_monad value :=
  let* result := findLvalue obj
  in match result with
  | ValHeader (MkHeader valid fields) => mret (ValBool valid)
  | _ => state_fail Internal
  end.

Definition evalSetBool (obj: lvalue) (valid: bool) : env_monad unit :=
  let* value := findLvalue obj in
  match value with
  | ValHeader (MkHeader _ fields) =>
    updateLvalue obj (ValHeader (MkHeader valid fields))
  | _ => state_fail Internal
  end.

Definition evalPopFront (obj: lvalue) (args: list (option value)) : env_monad unit :=
  match args with
  | Some (ValInt count) :: nil => 
      let* value := findLvalue obj in
      match value with
      | ValHeaderStack size nextIndex elements =>
        match rotateLeft elements count (MkHeader false (MStr.Raw.empty _)) with
        | None => state_fail Internal
        | Some elements' =>
          let value' := ValHeaderStack size (nextIndex - count) elements' in
          updateLvalue obj value
        end
      | _ => state_fail Internal
      end
  | _ => state_fail Internal
  end.

Definition evalPushFront (obj: lvalue) (args: list (option value)) : env_monad unit :=
  match args with
  | Some (ValInt count) :: nil => 
      let* value := findLvalue obj in
      match value with
      | ValHeaderStack size nextIndex elements =>
        match rotateRight elements count (MkHeader false (MStr.Raw.empty _)) with
        | None => state_fail Internal
        | Some elements' =>
          let nextIndex' := min size (nextIndex + count) in
          let value' := ValHeaderStack size nextIndex' elements' in
          updateLvalue obj value
        end
      | _ => state_fail Internal
      end
  | _ => state_fail Internal
  end.

Definition evalBuiltinFunc (name: string) (obj: lvalue) (args: list (option value)) : env_monad value :=
  match name with
  | "isValid" => evalIsValid obj
  | "setValid" => dummyValue (evalSetBool obj true)
  | "setInvalid" => dummyValue (evalSetBool obj false)
  | "pop_front" => dummyValue (evalPopFront obj args)
  | "push_front" => dummyValue (evalPushFront obj args)
  | _ => state_fail Internal
  end.

Fixpoint evalArguments (args: list (option expression)) : env_monad (list (option value)) :=
  match args with
  | nil => mret nil
  | Some arg :: args' =>
    let* val := evalExpression arg in
    let* vals := evalArguments args' in
    mret (Some val :: vals)
  | None :: args' =>
    let* vals := evalArguments args' in
    mret (None :: vals)
  end.

Fixpoint evalBlock (blk: block) : env_monad unit :=
  match blk with
  | BlockCons stmt rest =>
    evalStatement stmt;;
    evalBlock rest
  | BlockEmpty => mret tt
  end

with evalStatement (stmt: statement) : env_monad unit :=
  match stmt with
  | MethodCall func type_args args =>
    let* func' := evalExpression func in
    let* args' := evalArguments args in
    match func' with
    | ValBuiltinFunc name obj => tossValue (evalBuiltinFunc name obj args')
    | _ => mret tt (* TODO: other function types *)
    end
  | Assignment lhs rhs =>
    let* lval := evalLvalue lhs in
    let* val := evalExpression rhs in
    updateLvalue lval val
  | BlockStatement block =>
    mapEnv pushScope;;
    evalBlock block;;
    liftEnvFn popScope
  | StatementConstant type name init =>
    let* value := evalExpression init in
    insertEnvironment name value
  | StatementVariable type name init =>
    let* value :=
       match init with
       | None => mret (defaultValue type)
       | Some expr => evalExpression expr
       end
    in
    insertEnvironment name value
  end.