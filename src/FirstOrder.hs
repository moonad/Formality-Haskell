module FirstOrder where

import Data.Char(chr)
import Data.Sequence hiding (reverse)
import Control.Monad.ST
import Control.Monad.State
import Data.UnionFind.ST
import qualified Data.Map.Strict as M
import SimplerCore

data Term'
  = Rec' Int
  | Var' Int
  | Lam' Int Term' Term'
  | App' Int Term' Term'
  | All' Int Term' Term'
  | Mu' Term'
  | Any'
  | Typ'
  | Val' Int
  | Num'
  deriving (Eq, Show, Ord)

shiftRec' :: Term' -> Int -> Int -> Term'
shiftRec' term' inc dep = case term' of
  Lam' i h b -> Lam' i (shiftRec' h inc dep) (shiftRec' b inc dep)
  All' i h b -> All' i (shiftRec' h inc dep) (shiftRec' b inc dep)
  App' i f a -> App' i (shiftRec' f inc dep) (shiftRec' a inc dep)
  Mu'  t     -> Mu'  (shiftRec' t inc (dep + 1))
  Rec' i     -> Rec' (if i < dep then i else (i + inc))
  _          -> term'

substRec' :: Term' -> Term' -> Int -> Term'
substRec' term' v dep = case term' of
  All' i h b   -> All' i (substRec' h v dep) (substRec' b v dep)
  Lam' i h b   -> Lam' i (substRec' h v dep) (substRec' b v dep)
  App' i f a   -> App' i (substRec' f v dep) (substRec' a v dep)
  Mu'  t       -> Mu'  (substRec' t vR (dep + 1))
  Rec' i       -> if i == dep then v else Rec' (i - if i > dep then 1 else 0)
  _            -> term'
  where
    vR = shiftRec' v 1 0

unroll' :: Term' -> Term'
unroll' term' = case term' of
  All' i h b -> All' i (unroll' h) (unroll' b)
  Lam' i h b -> Lam' i (unroll' h) (unroll' b)
  App' i f a -> App' i (unroll' f) (unroll' a)
  Mu'  t     -> substRec' t (Mu' t) 0
  _          -> term'

encode :: Term -> Term'
encode term = go term (\x -> x)
  where
  go :: Term -> (Term -> Term) -> Term'
  go term sigma = case term of
    Var i     -> Var' i
    Rec i     -> Rec' i
    All _ h b -> All' max (go h sigma) (go (substVar b (Var (max+1)) 0) sigma)
    Lam _ h b -> Lam' max (go h sigma) (go (substVar b (Var (max+1)) 0) sigma)
    App f t   -> App' max (go f sigma) (go t sigma)
    Mu  _ t   -> Mu'  (go t (\t -> sigma (substRec t (Var max) 0)))
    Any       -> Any'
    Typ       -> Typ'
    Num       -> Num'
    Val i     -> Val' i
    where max = maxFreeVar (sigma term)

alphabet :: Int -> String
alphabet x = reverse (go x)
  where go x = chr (rest+97) : (if div <= 0 then "" else go (div-1)) where (div, rest) = divMod x 26

toVar :: Int -> [Int] -> Int
toVar i lams = go i lams 0 where
  go i [] depth = i + depth
  go i (m : lams) depth = if m < i then depth else go i lams (depth + 1)

decode :: Term' -> Term
decode term' = go term' 0 []
  where
  go term' count lams = case term' of
    Var' i     -> Var (toVar i lams)
    All' m h b -> All (alphabet count) (go h count lams) (go b (count+1) (m : lams))
    Lam' m h b -> Lam (alphabet count) (go h count lams) (go b (count+1) (m : lams))
    App' m f t -> App (go f count lams) (go t count lams)
    Mu'  t     -> Mu  (alphabet count) (go t (count+1) lams)
    Rec' i     -> Rec i
    Any'       -> Any
    Typ'       -> Typ
    Num'       -> Num
    Val' i     -> Val i

-- Equality algorithm
data Node a = Leaf | Branch a a

sameNode :: Term' -> Term' -> Maybe (Node (Term', Term'))
sameNode t@(Mu' _) s                 = sameNode (unroll' t) s
sameNode t s@(Mu' _)                 = sameNode t (unroll' s)
sameNode (All' i h b) (All' j h' b') = if i == j then Just $ Branch (h, h') (b, b') else Nothing
sameNode (Lam' i h b) (Lam' j h' b') = if i == j then Just $ Branch (h, h') (b, b') else Nothing
sameNode (App' i f a) (App' j f' a') = if i == j then Just $ Branch (f, f') (a, a') else Nothing
sameNode (Var' i) (Var' j)           = if i == j then Just Leaf else Nothing
sameNode (Rec' i) (Rec' j)           = if i == j then Just Leaf else Nothing
sameNode (Val' i) (Val' j)           = if i == j then Just Leaf else Nothing
sameNode Any' Any'                   = Just Leaf
sameNode Typ' Typ'                   = Just Leaf
sameNode Num' Num'                   = Just Leaf
sameNode _ _                         = Nothing

-- Gives a union-find partition of all subterms of a sequence of terms with a mapping of each subterm to their respective pointer in the partition
allSubterms :: Seq Term' -> ST s (M.Map Term' (Point s Term'))
allSubterms terms = go terms M.empty where
  go Empty map = return map
  go (t :<| ts) map = do
    let alteration x = case x of
          Nothing -> do p <- fresh t
                        return (Just p)
          Just p -> return (Just p)
    map' <- M.alterF alteration t map
    if M.size map == M.size map'
      then go ts map'
      else case t of
             App' _ f t -> go (ts :|> f :|> t) map'
             All' _ h b -> go (ts :|> h :|> b) map'
             Lam' _ h b -> go (ts :|> h :|> b) map'
             Mu'  _     -> go (unroll' t :<| ts) map'
             _          -> go ts map'

equalTerms :: Term -> Term -> Bool
equalTerms term1 term2 = runST $ do
  let term1' = encode term1
  let term2' = encode term2
  map <- allSubterms $ fromList [term1', term2']
  go [(term1', term2')] map
  where
    go [] map = return True
    go ((term1, term2) : pairs) map = case sameNode term1 term2 of
      Just (Branch pair1 pair2) -> do
        r1 <- repr (map M.! term1)
        r2 <- repr (map M.! term2)
        if r1 == r2
          then go pairs map
          else union r1 r2 >> go (pair1 : pair2 : pairs) map
      Just Leaf -> union (map M.! term1) (map M.! term2) >> go pairs map
      Nothing -> return False

-- Tests
forall n = All n Typ
impl a b = All "" a (shiftVar b 1 0)

test1 = forall "a" $ Mu "X" $ impl (Var 0) $ forall "b" $ impl (Var 0) (Rec 0)
test2 = Mu "X" $ forall "a" $ impl (forall "c" $ impl (Var 1) (Var 0)) $ forall "b" $ impl (Var 0) (Rec 0)

-- Equal terms
test3 = forall "a" $ Mu "X" $ impl (Var 0) $ impl (Var 0) $ impl (Var 0) (Rec 0)
test4 = forall "a" $ Mu "X" $ impl (Var 0) $ impl (Var 0) (Rec 0)
