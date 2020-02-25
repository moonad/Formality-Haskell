module Core where

import qualified Data.Map.Strict as M
import           Data.Text                  (Text)
import qualified Data.Text                  as T

import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Except

type Name = Text
data Eras = Eras  -- Erase from runtime
          | Keep  -- Keep at runtime
          -- | EHol Name  -- Erasure metavariable (probably not needed)
          deriving (Show, Eq, Ord)

data Term
  = Var Int                    -- Variable
  | Typ                        -- Type type
  | All Name Term Eras Term    -- Forall
  | Lam Name Term Eras Term    -- Lambda
  | App Term Term Eras         -- Application
  | Slf Name Term              -- Self-type
  | New Term Term              -- Self-type introduction
  | Use Term                   -- Self-type elimination
  | Num                        -- Number type
  | Val Int                    -- Number Value
  | Op1 Op Int Term            -- Unary operation (curried)
  | Op2 Op Term Term           -- Binary operation
  | Ite Term Term Term         -- If-then-else
  | Ann Term Term              -- Type annotation
  | Log Term Term              -- inline log
  | Hol Name                   -- type hole or metavariable
--  | Let Name Term Term         -- locally scoped definition
  | Ref Name                   -- reference to a globally scoped definition
  deriving (Eq, Show, Ord)

data Op
  = ADD | SUB | MUL | DIV | MOD
  -- | POW | AND | BOR | XOR | NOT | SHR | SHL | GTH | LTH | EQL
  deriving (Eq, Show, Ord)

-- shift DeBruijn indices in term by an increment at/greater than a depth
shift :: Term -> Int -> Int -> Term
shift term inc dep = case term of
  Var i        -> Var (if i < dep then i else (i + inc))
  Typ          -> Typ
  All n h e b  -> All n (shift h inc dep) e (shift b inc (dep + 1))
  Lam n h e b  -> Lam n (shift h inc dep) e (shift b inc (dep + 1))
  App f a e    -> App (shift f inc dep) (shift a inc dep) e
  Slf n t      -> Slf n (shift t inc (dep + 1))
  New t x      -> New (shift t inc dep) (shift x inc dep)
  Use x        -> Use (shift x inc dep)
  Num          -> Num
  Val n        -> Val n
  Op1 o a b    -> Op1 o a (shift b inc dep)
  Op2 o a b    -> Op2 o (shift a inc dep) (shift b inc dep)
  Ite c t f    -> Ite (shift c inc dep) (shift t inc dep) (shift f inc dep)
  Ann t x      -> Ann (shift t inc dep) (shift x inc dep)
  Log m x      -> Log (shift m inc dep) (shift x inc dep)
  Hol n        -> Hol n
  Ref n        -> Ref n

-- substitute a value for an index at a certain depth
subst :: Term -> Term -> Int -> Term
subst term v dep =
  let v' = shift v 1 0 in
  case term of
  Var i       -> if i == dep then v else Var (i - if i > dep then 1 else 0)
  Typ         -> Typ
  All n h e b -> All n (subst h v dep) e (subst b v' (dep + 1))
  Lam n h e b -> Lam n (subst h v dep) e (subst b v' (dep + 1))
  App f a e   -> App (subst f v dep) (subst a v dep) e
  Slf n t     -> Slf n (subst t v' (dep + 1))
  New t x     -> New (subst t v dep) (subst x v dep)
  Use x       -> Use (subst x v dep)
  Num         -> Num
  Val n       -> Val n
  Op1 o a b   -> Op1 o a (subst b v dep)
  Op2 o a b   -> Op2 o (subst a v dep) (subst b v dep)
  Ite c t f   -> Ite (subst c v dep) (subst t v dep) (subst f v dep)
  Ann t x     -> Ann (subst t v dep) (subst x v dep)
  Log m x     -> Log (subst m v dep) (subst x v dep)
  Hol n       -> Hol n
  Ref n       -> Ref n

substMany :: Term -> [Term] -> Int -> Term
substMany t vals d = go t vals d 0
  where
    l = length vals - 1
    go t (v:vs) d i = go (subst t (shift v (l - i) 0) (d + l - i)) vs d (i + 1)
    go t [] d i = t

type Defs = M.Map Text Term

-- deBruijn
eval :: Term -> Defs -> Term
eval term defs = case term of
  Var i       -> Var i
  Typ         -> Typ
  All n h e b -> All n h e b
  Lam n h e b -> Lam n h e (eval b defs)
  App f a e   -> case eval f defs of
    Lam n' h' e b'  -> eval (subst b' a 0) defs
    f               -> App f (eval a defs) e
  Slf n t     -> Slf n t
  New t x     -> eval x defs
  Use x       -> eval x defs
  Num         -> Num
  Val n       -> Val n
  Op1 o a b    -> case eval b defs of
    Val n -> Val $ op o a n
    x     -> Op1 o a x
  Op2 o a b   -> case eval a defs of
    Val n -> eval (Op1 o n b) defs
    x     -> Op2 o x b
  Ite c t f   -> case eval c defs of
    Val n -> if n > 0 then eval t defs else eval f defs
    x     -> Ite x (eval t defs) (eval f defs)
  Ann t x     -> eval x defs
  Log m x     -> Log (eval m defs) (eval x defs)
  Hol n       -> Hol n
  Ref n       -> dereference n defs

dereference :: Name -> Defs -> Term
dereference n defs = maybe (Ref n) (\x -> eval x defs) $ M.lookup n defs

op :: Op -> Int -> Int -> Int
op o a b = case o of
  ADD -> a + b
  SUB -> a - b
  MUL -> a * b
  DIV -> a `div` b
  MOD -> a `mod` b
  --POW -> a ^ b

erase :: Term -> Term
erase term = case term of
  All n h e b    -> All n (erase h) e (erase b)
  Lam n h Eras b -> erase $ subst b (Hol "#erased") 0
  Lam n h e b    -> Lam n (erase h) e (erase b)
  App f a Eras   -> erase f
  App f a e      -> App (erase f) (erase a) e
  Op1 o a b      -> Op1 o a (erase b)
  Op2 o a b      -> Op2 o (erase a) (erase b)
  Ite c t f      -> Ite (erase c) (erase t) (erase f)
  Slf n t        -> Slf n (erase t)
  New t x        -> erase x
  Use x          -> erase x
  Ann t x        -> erase x
  Log m x        -> Log (erase m) (erase x)
  _ -> term
