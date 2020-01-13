module Unify where

import           Data.Foldable
import qualified Data.Map.Strict      as M
import           Data.Set             (Set)
import qualified Data.Set             as Set
import           Data.Text            (Text)
import qualified Data.Text            as T

import           Control.Monad.Except
import           Control.Monad.Reader
import           Control.Monad.RWS    hiding (All)
import           Control.Monad.State
import           Control.Monad.Trans

import           Core

substHole :: Term -> Name -> Term -> Term
substHole new nam t = let go = substHole new nam in case t of
  All n h e b -> All n (go h) e (go b)
  Lam n h e b -> Lam n (go h) e (go b)
  App f a e   -> App (go f) (go a) e
  Slf n t     -> Slf n (go t)
  New t x     -> New (go t) (go x)
  Use x       -> Use (go x)
  Op1 o a b   -> Op1 o a (go b)
  Op2 o a b   -> Op2 o (go a) (go b)
  Ite c t f   -> Ite (go c) (go t) (go f)
  Hol n       -> if nam == n then new else Hol n
  Ann t x     -> Ann (go t) (go x)
  Log m x     -> Log (go m) (go x)
  x           -> x

holes :: Term -> Set Name
holes t = go t Set.empty
  where
    go t s = case t of
      All _ h _ b -> go h s <> go b s
      Lam _ h _ b -> go h s <> go b s
      App f a _   -> go f s <> go a s
      Slf _ t     -> go t s
      New t x     -> go t s <> go x s
      Use x       -> go x s
      Op1 _ _ b   -> go b s
      Op2 _ a b   -> go a s <> go b s
      Ite c t f   -> go c s <> go t s <> go f s
      Ann t x     -> go t s <> go x s
      Log m x     -> go m s <> go x s
      _           -> s

isClosed :: Term -> Bool
isClosed t = go t 0
  where
    go t d = case t of
      Var i       -> i < d
      All n h e b -> go h d && go b (d + 1)
      Lam n h e b -> go h d && go b (d + 1)
      App f a e   -> go f d && go a d
      Slf n t     -> go t (d + 1)
      New t x     -> go t d && go x d
      Use x       -> go x d
      Op1 o a b   -> go b d
      Op2 o a b   -> go a d && go b d
      Ite c t f   -> go c d && go t d && go f d
      Ann t x     -> go t d && go x d
      Log m x     -> go m d && go x d
      Ref n       -> False
      _           -> True

isStuck :: Term -> Bool
isStuck (Hol _)     = True
isStuck (App f _ _) = isStuck f
isStuck _           = False

peelApTelescope :: Term -> (Term, [Term])
peelApTelescope t = go t []
  where
    go (App f a _) as = go f (a : as)
    go t as           = (t, as)

applyApTelescope :: Term -> [Term] -> Term
applyApTelescope = foldl (\x y -> App x y Keep)

type Constraint = (Term, Term)

-- remove Environment by resolving Defs and [Binders]
--regularize :: PreConstraint -> Constraint
--regularize (env, t1, t2) = undefined
--  where
--  t1' = unbind (_context env) t1
--  t2' = unbind (_context env) t2
--
--unbind :: [Binder] -> Term -> Term
--unbind [] x = x
--unbind ((n,t,e):bs) = unbind bs (Lam n t e x)

-- resolve Defs
dereference :: Term -> Defs -> Term
dereference t ds = undefined



type Subst = M.Map Name Term

data UnifyEnv = UnifyEnv
data UnifyLog = UnifyLog
data UnifyState = UnifyState
  { _varCount :: Int
  } deriving (Show, Eq)

type Unify = ExceptT UnifyError (RWS UnifyEnv UnifyLog UnifyState)

data UnifyError
  = UnificationMismatch Term Term
  deriving Show

-- Rigid-Rigid constraint
-- simplify :: Constraint -> Unify (Set Constraint)
-- simplify (env, t1, t2) = do
--   b <- equal env t1 t2
--   when b (return $ Set.empty)
--   case (t1,t2) of
--     (Var
--  | t1 == t2 && Set.null (holes t1) = return $ Set.empty
-- | eval' t1 /= t1 = simplify (eval' t1, t2)
-- | eval' t2 /= t2 = simplify (t1, eval' t2)
-- | (Var m, ctxM) <- peelApTelescope t1
-- , (Var n, ctxN) <- peelApTelescope t1
--   = do
--     guard (isFree m t1 && isFree n t2)
--     guard (m == n && length ctxM == length ctxN)
--     fold <$> mapM simplify (zip ctxM ctxN)
-- | Lam _ h1 b1 e1 <- t1
-- , Lam _ h2 b2 e2 <- t2 
--   = do
--     guard (e1 == e2)
--     v <- getFree

--
-- | isStuck t1 || isStuck t2 = Set.singleton (t1,t2)
----  | otherwise = Set.empty

eval' t = eval t M.empty

--data IsEq = Eql Term Term | And IsEq IsEq | Or IsEq IsEq | Ret Bool
--
--equal :: Term -> Term -> Unify Bool
--equal a b = go (Eql a b)
--  where
--    go :: IsEq -> Check ()
--    go t = case t of
--      Ret False -> (TypeMismatch a b <$> ask) >>= throwError
--      Ret True  -> return ()
--      _         -> (step t) >>= go
--
--    step :: IsEq -> Check IsEq
--    step t = case t of
--      Eql a b -> do
--        defs  <- asks _defs
--        --holes  <- gets _holes
--        let ex = case (eval a M.empty, eval b M.empty) of
--              (Ref aN, Ref bN) -> if aN == bN then (return $ Just (Ret True))
--                  else return Nothing
--              (App aF aA _, App bF bA _) -> return $ Just (And (Eql aF bF) (Eql aA bA))
--              _ -> return Nothing
--        let ey = case (eval a defs, eval b defs) of
--              (Var i, Var j) -> Ret $ i == j
--              (Typ, Typ) -> Ret True
--              (All _ aH aB _, All _ bH bB _) -> And (Eql aH bH) (Eql aB bB)
--              (Lam _ aH aB _, Lam _ bH bB _) -> Eql aB bB
--              (App aF aA _, App bF bA _)     -> And (Eql aF bF) (Eql aA bA)
--              (Slf _ aT, Slf _ bT)           -> Eql aT bT
--              (New _ aX, New _ bX)           -> Eql aX bX
--              (Use aX, Use bX)               -> Eql aX bX
--              (Num, Num)                     -> Ret True
--              (Val i, Val j)                 -> Ret $ i == j
--              (Op1 aO aX aY, Op1 bO bX bY)   ->
--                if aO /= bO then Ret False else And (Ret $ aX == bX) (Eql aY bY)
--              (Op2 aO aX aY, Op2 bO bX bY)   ->
--                if aO /= bO then Ret False else And (Eql aX bX) (Eql aY bY)
--              (Ite aC aT aF, Ite bC bT bF)   -> And (Eql aC bC) (Eql aT bT)
--              (Ann aT aV, Ann bT bV)         -> Eql aV bV
--              _                              -> Ret False
--        (maybe ey (\x -> Or x ey)) <$> ex
--      And (Ret False) _ -> return $ Ret False
--      And (Ret True) y  -> return $ y
--      And _ (Ret False) -> return $ Ret False
--      And x (Ret True)  -> return $ x
--      And x y           -> do x' <- step x; y' <- step y; return $ And x' y'
--      Or (Ret True) y   -> return $ Ret True
--      Or (Ret False) y  -> return $ y
--      Or x (Ret True)   -> return $ Ret True
--      Or x (Ret False)  -> return $ x
--      Or x y            ->  do x' <- step x; y' <- step y; return $ Or x' y'
--      Ret v             -> return $ Ret v