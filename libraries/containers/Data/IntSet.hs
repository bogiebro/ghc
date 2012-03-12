#if !defined(TESTING) && __GLASGOW_HASKELL__ >= 703
{-# LANGUAGE Trustworthy #-}
#endif
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.IntSet
-- Copyright   :  (c) Daan Leijen 2002
-- License     :  BSD-style
-- Maintainer  :  libraries@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- An efficient implementation of integer sets.
--
-- Since many function names (but not the type name) clash with
-- "Prelude" names, this module is usually imported @qualified@, e.g.
--
-- >  import Data.IntSet (IntSet)
-- >  import qualified Data.IntSet as IntSet
--
-- The implementation is based on /big-endian patricia trees/.  This data
-- structure performs especially well on binary operations like 'union'
-- and 'intersection'.  However, my benchmarks show that it is also
-- (much) faster on insertions and deletions when compared to a generic
-- size-balanced set implementation (see "Data.Set").
--
--    * Chris Okasaki and Andy Gill,  \"/Fast Mergeable Integer Maps/\",
--      Workshop on ML, September 1998, pages 77-86,
--      <http://citeseer.ist.psu.edu/okasaki98fast.html>
--
--    * D.R. Morrison, \"/PATRICIA -- Practical Algorithm To Retrieve
--      Information Coded In Alphanumeric/\", Journal of the ACM, 15(4),
--      October 1968, pages 514-534.
--
-- Many operations have a worst-case complexity of /O(min(n,W))/.
-- This means that the operation can become linear in the number of
-- elements with a maximum of /W/ -- the number of bits in an 'Int'
-- (32 or 64).
-----------------------------------------------------------------------------

-- It is essential that the bit fiddling functions like mask, zero, branchMask
-- etc are inlined. If they do not, the memory allocation skyrockets. The GHC
-- usually gets it right, but it is disastrous if it does not. Therefore we
-- explicitly mark these functions INLINE.

module Data.IntSet (
            -- * Set type
#if !defined(TESTING)
              IntSet          -- instance Eq,Show
#else
              IntSet(..)      -- instance Eq,Show
#endif

            -- * Operators
            , (\\)

            -- * Query
            , null
            , size
            , member
            , notMember
            , isSubsetOf
            , isProperSubsetOf

            -- * Construction
            , empty
            , singleton
            , insert
            , delete

            -- * Combine
            , union
            , unions
            , difference
            , intersection

            -- * Filter
            , filter
            , partition
            , split
            , splitMember

            -- * Map
            , map

            -- * Folds
            , foldr
            , foldl
            -- ** Strict folds
            , foldr'
            , foldl'
            -- ** Legacy folds
            , fold

            -- * Min\/Max
            , findMin
            , findMax
            , deleteMin
            , deleteMax
            , deleteFindMin
            , deleteFindMax
            , maxView
            , minView

            -- * Conversion

            -- ** List
            , elems
            , toList
            , fromList

            -- ** Ordered list
            , toAscList
            , fromAscList
            , fromDistinctAscList

            -- * Debugging
            , showTree
            , showTreeWith

#if defined(TESTING)
            -- * Internals
            , match
#endif
            ) where


import Prelude hiding (lookup,filter,foldr,foldl,null,map)
import Data.Bits 

import qualified Data.List as List
import Data.Monoid (Monoid(..))
import Data.Maybe (fromMaybe)
import Data.Typeable
import Control.DeepSeq (NFData)

#if __GLASGOW_HASKELL__
import Text.Read
import Data.Data (Data(..), mkNoRepType)
#endif

#if __GLASGOW_HASKELL__ >= 503
import GHC.Exts ( Word(..), Int(..), shiftRL# )
#elif __GLASGOW_HASKELL__
import Word
import GlaExts ( Word(..), Int(..), shiftRL# )
#else
import Data.Word
#endif

-- Use macros to define strictness of functions.
-- STRICT_x_OF_y denotes an y-ary function strict in the x-th parameter.
-- We do not use BangPatterns, because they are not in any standard and we
-- want the compilers to be compiled by as many compilers as possible.
#define STRICT_1_OF_2(fn) fn arg _ | arg `seq` False = undefined

infixl 9 \\{-This comment teaches CPP correct behaviour -}

-- A "Nat" is a natural machine word (an unsigned Int)
type Nat = Word

natFromInt :: Int -> Nat
natFromInt i = fromIntegral i
{-# INLINE natFromInt #-}

intFromNat :: Nat -> Int
intFromNat w = fromIntegral w
{-# INLINE intFromNat #-}

shiftRL :: Nat -> Int -> Nat
#if __GLASGOW_HASKELL__
{--------------------------------------------------------------------
  GHC: use unboxing to get @shiftRL@ inlined.
--------------------------------------------------------------------}
shiftRL (W# x) (I# i)
  = W# (shiftRL# x i)
#else
shiftRL x i   = shiftR x i
{-# INLINE shiftRL #-}
#endif

{--------------------------------------------------------------------
  Operators
--------------------------------------------------------------------}
-- | /O(n+m)/. See 'difference'.
(\\) :: IntSet -> IntSet -> IntSet
m1 \\ m2 = difference m1 m2

{--------------------------------------------------------------------
  Types  
--------------------------------------------------------------------}

-- The order of constructors of IntSet matters when considering performance.
-- Currently in GHC 7.0, when type has 3 constructors, they are matched from
-- the first to the last -- the best performance is achieved when the
-- constructors are ordered by frequency.
-- On GHC 7.0, reordering constructors from Nil | Tip | Bin to Bin | Tip | Nil
-- improves the containers_benchmark by 11% on x86 and by 9% on x86_64.

-- | A set of integers.
data IntSet = Bin {-# UNPACK #-} !Prefix {-# UNPACK #-} !Mask !IntSet !IntSet
            | Tip {-# UNPACK #-} !Int
            | Nil
-- Invariant: Nil is never found as a child of Bin.
-- Invariant: The Mask is a power of 2.  It is the largest bit position at which
--            two elements of the set differ.
-- Invariant: Prefix is the common high-order bits that all elements share to
--            the left of the Mask bit.
-- Invariant: In Bin prefix mask left right, left consists of the elements that
--            don't have the mask bit set; right is all the elements that do.


type Prefix = Int
type Mask   = Int

instance Monoid IntSet where
    mempty  = empty
    mappend = union
    mconcat = unions

#if __GLASGOW_HASKELL__

{--------------------------------------------------------------------
  A Data instance  
--------------------------------------------------------------------}

-- This instance preserves data abstraction at the cost of inefficiency.
-- We omit reflection services for the sake of data abstraction.

instance Data IntSet where
  gfoldl f z is = z fromList `f` (toList is)
  toConstr _    = error "toConstr"
  gunfold _ _   = error "gunfold"
  dataTypeOf _  = mkNoRepType "Data.IntSet.IntSet"

#endif

{--------------------------------------------------------------------
  Query
--------------------------------------------------------------------}
-- | /O(1)/. Is the set empty?
null :: IntSet -> Bool
null Nil = True
null _   = False

-- | /O(n)/. Cardinality of the set.
size :: IntSet -> Int
size t
  = case t of
      Bin _ _ l r -> size l + size r
      Tip _ -> 1
      Nil   -> 0

-- The 'go' function in the member and lookup causes 10% speedup, but also an
-- increased memory allocation. It does not cause speedup with other methods
-- like insert and delete, so it is present only in member and lookup.

-- Also mind the 'nomatch' line in member definition, which is not present in
-- lookup and not present in IntMap.hs. That condition stops the search if the
-- prefix of current vertex is different that the element looked for. The
-- member is correct both with and without this condition. With this condition,
-- elements not present are rejected sooner, but a little bit more work is done
-- for the elements in the set (we are talking about 3-5% slowdown). Any of
-- the solutions is better than the other, because we do not know the
-- distribution of input data. Current state is historic.

-- | /O(min(n,W))/. Is the value a member of the set?
member :: Int -> IntSet -> Bool
member x = x `seq` go
  where
    go (Bin p m l r)
      | nomatch x p m = False
      | zero x m      = go l
      | otherwise     = go r
    go (Tip y) = x == y
    go Nil = False

-- | /O(min(n,W))/. Is the element not in the set?
notMember :: Int -> IntSet -> Bool
notMember k = not . member k

-- 'lookup' is used by 'intersection' for left-biasing
lookup :: Int -> IntSet -> Maybe Int
lookup k = k `seq` go
  where
    go (Bin _ m l r)
      | zero k m  = go l
      | otherwise = go r
    go (Tip kx)
      | k == kx   = Just kx
      | otherwise = Nothing
    go Nil = Nothing

{--------------------------------------------------------------------
  Construction
--------------------------------------------------------------------}
-- | /O(1)/. The empty set.
empty :: IntSet
empty
  = Nil

-- | /O(1)/. A set of one element.
singleton :: Int -> IntSet
singleton x
  = Tip x

{--------------------------------------------------------------------
  Insert
--------------------------------------------------------------------}
-- | /O(min(n,W))/. Add a value to the set. When the value is already
-- an element of the set, it is replaced by the new one, ie. 'insert'
-- is left-biased.
insert :: Int -> IntSet -> IntSet
insert x t = x `seq`
  case t of
    Bin p m l r
      | nomatch x p m -> join x (Tip x) p t
      | zero x m      -> Bin p m (insert x l) r
      | otherwise     -> Bin p m l (insert x r)
    Tip y
      | x==y          -> Tip x
      | otherwise     -> join x (Tip x) y t
    Nil -> Tip x

-- right-biased insertion, used by 'union'
insertR :: Int -> IntSet -> IntSet
insertR x t = x `seq`
  case t of
    Bin p m l r
      | nomatch x p m -> join x (Tip x) p t
      | zero x m      -> Bin p m (insert x l) r
      | otherwise     -> Bin p m l (insert x r)
    Tip y
      | x==y          -> t
      | otherwise     -> join x (Tip x) y t
    Nil -> Tip x

-- | /O(min(n,W))/. Delete a value in the set. Returns the
-- original set when the value was not present.
delete :: Int -> IntSet -> IntSet
delete x t = x `seq`
  case t of
    Bin p m l r
      | nomatch x p m -> t
      | zero x m      -> bin p m (delete x l) r
      | otherwise     -> bin p m l (delete x r)
    Tip y
      | x==y          -> Nil
      | otherwise     -> t
    Nil -> Nil


{--------------------------------------------------------------------
  Union
--------------------------------------------------------------------}
-- | The union of a list of sets.
unions :: [IntSet] -> IntSet
unions xs
  = foldlStrict union empty xs


-- | /O(n+m)/. The union of two sets. 
union :: IntSet -> IntSet -> IntSet
union t1@(Bin p1 m1 l1 r1) t2@(Bin p2 m2 l2 r2)
  | shorter m1 m2  = union1
  | shorter m2 m1  = union2
  | p1 == p2       = Bin p1 m1 (union l1 l2) (union r1 r2)
  | otherwise      = join p1 t1 p2 t2
  where
    union1  | nomatch p2 p1 m1  = join p1 t1 p2 t2
            | zero p2 m1        = Bin p1 m1 (union l1 t2) r1
            | otherwise         = Bin p1 m1 l1 (union r1 t2)

    union2  | nomatch p1 p2 m2  = join p1 t1 p2 t2
            | zero p1 m2        = Bin p2 m2 (union t1 l2) r2
            | otherwise         = Bin p2 m2 l2 (union t1 r2)

union (Tip x) t = insert x t
union t (Tip x) = insertR x t  -- right bias
union Nil t     = t
union t Nil     = t


{--------------------------------------------------------------------
  Difference
--------------------------------------------------------------------}
-- | /O(n+m)/. Difference between two sets. 
difference :: IntSet -> IntSet -> IntSet
difference t1@(Bin p1 m1 l1 r1) t2@(Bin p2 m2 l2 r2)
  | shorter m1 m2  = difference1
  | shorter m2 m1  = difference2
  | p1 == p2       = bin p1 m1 (difference l1 l2) (difference r1 r2)
  | otherwise      = t1
  where
    difference1 | nomatch p2 p1 m1  = t1
                | zero p2 m1        = bin p1 m1 (difference l1 t2) r1
                | otherwise         = bin p1 m1 l1 (difference r1 t2)

    difference2 | nomatch p1 p2 m2  = t1
                | zero p1 m2        = difference t1 l2
                | otherwise         = difference t1 r2

difference t1@(Tip x) t2 
  | member x t2  = Nil
  | otherwise    = t1

difference Nil _     = Nil
difference t (Tip x) = delete x t
difference t Nil     = t



{--------------------------------------------------------------------
  Intersection
--------------------------------------------------------------------}
-- | /O(n+m)/. The intersection of two sets. 
intersection :: IntSet -> IntSet -> IntSet
intersection t1@(Bin p1 m1 l1 r1) t2@(Bin p2 m2 l2 r2)
  | shorter m1 m2  = intersection1
  | shorter m2 m1  = intersection2
  | p1 == p2       = bin p1 m1 (intersection l1 l2) (intersection r1 r2)
  | otherwise      = Nil
  where
    intersection1 | nomatch p2 p1 m1  = Nil
                  | zero p2 m1        = intersection l1 t2
                  | otherwise         = intersection r1 t2

    intersection2 | nomatch p1 p2 m2  = Nil
                  | zero p1 m2        = intersection t1 l2
                  | otherwise         = intersection t1 r2

intersection t1@(Tip x) t2 
  | member x t2  = t1
  | otherwise    = Nil
intersection t (Tip x) 
  = case lookup x t of
      Just y  -> Tip y
      Nothing -> Nil
intersection Nil _ = Nil
intersection _ Nil = Nil



{--------------------------------------------------------------------
  Subset
--------------------------------------------------------------------}
-- | /O(n+m)/. Is this a proper subset? (ie. a subset but not equal).
isProperSubsetOf :: IntSet -> IntSet -> Bool
isProperSubsetOf t1 t2
  = case subsetCmp t1 t2 of 
      LT -> True
      _  -> False

subsetCmp :: IntSet -> IntSet -> Ordering
subsetCmp t1@(Bin p1 m1 l1 r1) (Bin p2 m2 l2 r2)
  | shorter m1 m2  = GT
  | shorter m2 m1  = case subsetCmpLt of
                       GT -> GT
                       _ -> LT
  | p1 == p2       = subsetCmpEq
  | otherwise      = GT  -- disjoint
  where
    subsetCmpLt | nomatch p1 p2 m2  = GT
                | zero p1 m2        = subsetCmp t1 l2
                | otherwise         = subsetCmp t1 r2
    subsetCmpEq = case (subsetCmp l1 l2, subsetCmp r1 r2) of
                    (GT,_ ) -> GT
                    (_ ,GT) -> GT
                    (EQ,EQ) -> EQ
                    _       -> LT

subsetCmp (Bin _ _ _ _) _  = GT
subsetCmp (Tip x) (Tip y)  
  | x==y       = EQ
  | otherwise  = GT  -- disjoint
subsetCmp (Tip x) t        
  | member x t = LT
  | otherwise  = GT  -- disjoint
subsetCmp Nil Nil = EQ
subsetCmp Nil _   = LT

-- | /O(n+m)/. Is this a subset?
-- @(s1 `isSubsetOf` s2)@ tells whether @s1@ is a subset of @s2@.

isSubsetOf :: IntSet -> IntSet -> Bool
isSubsetOf t1@(Bin p1 m1 l1 r1) (Bin p2 m2 l2 r2)
  | shorter m1 m2  = False
  | shorter m2 m1  = match p1 p2 m2 && (if zero p1 m2 then isSubsetOf t1 l2
                                                      else isSubsetOf t1 r2)                     
  | otherwise      = (p1==p2) && isSubsetOf l1 l2 && isSubsetOf r1 r2
isSubsetOf (Bin _ _ _ _) _  = False
isSubsetOf (Tip x) t        = member x t
isSubsetOf Nil _            = True


{--------------------------------------------------------------------
  Filter
--------------------------------------------------------------------}
-- | /O(n)/. Filter all elements that satisfy some predicate.
filter :: (Int -> Bool) -> IntSet -> IntSet
filter predicate t
  = case t of
      Bin p m l r 
        -> bin p m (filter predicate l) (filter predicate r)
      Tip x 
        | predicate x -> t
        | otherwise   -> Nil
      Nil -> Nil

-- | /O(n)/. partition the set according to some predicate.
partition :: (Int -> Bool) -> IntSet -> (IntSet,IntSet)
partition predicate t
  = case t of
      Bin p m l r 
        -> let (l1,l2) = partition predicate l
               (r1,r2) = partition predicate r
           in (bin p m l1 r1, bin p m l2 r2)
      Tip x 
        | predicate x -> (t,Nil)
        | otherwise   -> (Nil,t)
      Nil -> (Nil,Nil)


-- | /O(min(n,W))/. The expression (@'split' x set@) is a pair @(set1,set2)@
-- where @set1@ comprises the elements of @set@ less than @x@ and @set2@
-- comprises the elements of @set@ greater than @x@.
--
-- > split 3 (fromList [1..5]) == (fromList [1,2], fromList [4,5])
split :: Int -> IntSet -> (IntSet,IntSet)
split x t
  = case t of
      Bin _ m l r
        | m < 0       -> if x >= 0 then let (lt,gt) = split' x l in (union r lt, gt)
                                   else let (lt,gt) = split' x r in (lt, union gt l)
                                   -- handle negative numbers.
        | otherwise   -> split' x t
      Tip y 
        | x>y         -> (t,Nil)
        | x<y         -> (Nil,t)
        | otherwise   -> (Nil,Nil)
      Nil             -> (Nil, Nil)

split' :: Int -> IntSet -> (IntSet,IntSet)
split' x t
  = case t of
      Bin p m l r
        | match x p m -> if zero x m then let (lt,gt) = split' x l in (lt,union gt r)
                                     else let (lt,gt) = split' x r in (union l lt,gt)
        | otherwise   -> if x < p then (Nil, t)
                                  else (t, Nil)
      Tip y 
        | x>y       -> (t,Nil)
        | x<y       -> (Nil,t)
        | otherwise -> (Nil,Nil)
      Nil -> (Nil,Nil)

-- | /O(min(n,W))/. Performs a 'split' but also returns whether the pivot
-- element was found in the original set.
splitMember :: Int -> IntSet -> (IntSet,Bool,IntSet)
splitMember x t
  = case t of
      Bin _ m l r
        | m < 0       -> if x >= 0 then let (lt,found,gt) = splitMember' x l in (union r lt, found, gt)
                                   else let (lt,found,gt) = splitMember' x r in (lt, found, union gt l)
                                   -- handle negative numbers.
        | otherwise   -> splitMember' x t
      Tip y 
        | x>y       -> (t,False,Nil)
        | x<y       -> (Nil,False,t)
        | otherwise -> (Nil,True,Nil)
      Nil -> (Nil,False,Nil)

splitMember' :: Int -> IntSet -> (IntSet,Bool,IntSet)
splitMember' x t
  = case t of
      Bin p m l r
         | match x p m ->  if zero x m then let (lt,found,gt) = splitMember x l in (lt,found,union gt r)
                                       else let (lt,found,gt) = splitMember x r in (union l lt,found,gt)
         | otherwise   -> if x < p then (Nil, False, t)
                                   else (t, False, Nil)
      Tip y 
        | x>y       -> (t,False,Nil)
        | x<y       -> (Nil,False,t)
        | otherwise -> (Nil,True,Nil)
      Nil -> (Nil,False,Nil)

{----------------------------------------------------------------------
  Min/Max
----------------------------------------------------------------------}

-- | /O(min(n,W))/. Retrieves the maximal key of the set, and the set
-- stripped of that element, or 'Nothing' if passed an empty set.
maxView :: IntSet -> Maybe (Int, IntSet)
maxView t
    = case t of
        Bin p m l r | m < 0 -> let (result,t') = maxViewUnsigned l in Just (result, bin p m t' r)
        Bin p m l r         -> let (result,t') = maxViewUnsigned r in Just (result, bin p m l t')            
        Tip y -> Just (y,Nil)
        Nil -> Nothing

maxViewUnsigned :: IntSet -> (Int, IntSet)
maxViewUnsigned t 
    = case t of
        Bin p m l r -> let (result,t') = maxViewUnsigned r in (result, bin p m l t')
        Tip y -> (y, Nil)
        Nil -> error "maxViewUnsigned Nil"

-- | /O(min(n,W))/. Retrieves the minimal key of the set, and the set
-- stripped of that element, or 'Nothing' if passed an empty set.
minView :: IntSet -> Maybe (Int, IntSet)
minView t
    = case t of
        Bin p m l r | m < 0 -> let (result,t') = minViewUnsigned r in Just (result, bin p m l t')            
        Bin p m l r         -> let (result,t') = minViewUnsigned l in Just (result, bin p m t' r)
        Tip y -> Just (y, Nil)
        Nil -> Nothing

minViewUnsigned :: IntSet -> (Int, IntSet)
minViewUnsigned t 
    = case t of
        Bin p m l r -> let (result,t') = minViewUnsigned l in (result, bin p m t' r)
        Tip y -> (y, Nil)
        Nil -> error "minViewUnsigned Nil"

-- | /O(min(n,W))/. Delete and find the minimal element.
-- 
-- > deleteFindMin set = (findMin set, deleteMin set)
deleteFindMin :: IntSet -> (Int, IntSet)
deleteFindMin = fromMaybe (error "deleteFindMin: empty set has no minimal element") . minView

-- | /O(min(n,W))/. Delete and find the maximal element.
-- 
-- > deleteFindMax set = (findMax set, deleteMax set)
deleteFindMax :: IntSet -> (Int, IntSet)
deleteFindMax = fromMaybe (error "deleteFindMax: empty set has no maximal element") . maxView


-- | /O(min(n,W))/. The minimal element of the set.
findMin :: IntSet -> Int
findMin Nil = error "findMin: empty set has no minimal element"
findMin (Tip x) = x
findMin (Bin _ m l r)
  |   m < 0   = find r
  | otherwise = find l
    where find (Tip x)        = x
          find (Bin _ _ l' _) = find l'
          find Nil            = error "findMin Nil"

-- | /O(min(n,W))/. The maximal element of a set.
findMax :: IntSet -> Int
findMax Nil = error "findMax: empty set has no maximal element"
findMax (Tip x) = x
findMax (Bin _ m l r)
  |   m < 0   = find l
  | otherwise = find r
    where find (Tip x)        = x
          find (Bin _ _ _ r') = find r'
          find Nil            = error "findMax Nil"


-- | /O(min(n,W))/. Delete the minimal element.
deleteMin :: IntSet -> IntSet
deleteMin = maybe (error "deleteMin: empty set has no minimal element") snd . minView

-- | /O(min(n,W))/. Delete the maximal element.
deleteMax :: IntSet -> IntSet
deleteMax = maybe (error "deleteMax: empty set has no maximal element") snd . maxView

{----------------------------------------------------------------------
  Map
----------------------------------------------------------------------}

-- | /O(n*min(n,W))/. 
-- @'map' f s@ is the set obtained by applying @f@ to each element of @s@.
-- 
-- It's worth noting that the size of the result may be smaller if,
-- for some @(x,y)@, @x \/= y && f x == f y@

map :: (Int->Int) -> IntSet -> IntSet
map f = fromList . List.map f . toList

{--------------------------------------------------------------------
  Fold
--------------------------------------------------------------------}
-- | /O(n)/. Fold the elements in the set using the given right-associative
-- binary operator. This function is an equivalent of 'foldr' and is present
-- for compatibility only.
--
-- /Please note that fold will be deprecated in the future and removed./
fold :: (Int -> b -> b) -> b -> IntSet -> b
fold = foldr
{-# INLINE fold #-}

-- | /O(n)/. Fold the elements in the set using the given right-associative
-- binary operator, such that @'foldr' f z == 'Prelude.foldr' f z . 'toAscList'@.
--
-- For example,
--
-- > toAscList set = foldr (:) [] set
foldr :: (Int -> b -> b) -> b -> IntSet -> b
foldr f z t =
  case t of Bin 0 m l r | m < 0 -> go (go z l) r -- put negative numbers before
            _                   -> go z t
  where
    go z' Nil           = z'
    go z' (Tip x)       = f x z'
    go z' (Bin _ _ l r) = go (go z' r) l
{-# INLINE foldr #-}

-- | /O(n)/. A strict version of 'foldr'. Each application of the operator is
-- evaluated before using the result in the next application. This
-- function is strict in the starting value.
foldr' :: (Int -> b -> b) -> b -> IntSet -> b
foldr' f z t =
  case t of Bin 0 m l r | m < 0 -> go (go z l) r -- put negative numbers before
            _                   -> go z t
  where
    STRICT_1_OF_2(go)
    go z' Nil           = z'
    go z' (Tip x)       = f x z'
    go z' (Bin _ _ l r) = go (go z' r) l
{-# INLINE foldr' #-}

-- | /O(n)/. Fold the elements in the set using the given left-associative
-- binary operator, such that @'foldl' f z == 'Prelude.foldl' f z . 'toAscList'@.
--
-- For example,
--
-- > toDescList set = foldl (flip (:)) [] set
foldl :: (a -> Int -> a) -> a -> IntSet -> a
foldl f z t =
  case t of Bin 0 m l r | m < 0 -> go (go z r) l -- put negative numbers before
            _                   -> go z t
  where
    STRICT_1_OF_2(go)
    go z' Nil           = z'
    go z' (Tip x)       = f z' x
    go z' (Bin _ _ l r) = go (go z' l) r
{-# INLINE foldl #-}

-- | /O(n)/. A strict version of 'foldl'. Each application of the operator is
-- evaluated before using the result in the next application. This
-- function is strict in the starting value.
foldl' :: (a -> Int -> a) -> a -> IntSet -> a
foldl' f z t =
  case t of Bin 0 m l r | m < 0 -> go (go z r) l -- put negative numbers before
            _                   -> go z t
  where
    STRICT_1_OF_2(go)
    go z' Nil           = z'
    go z' (Tip x)       = f z' x
    go z' (Bin _ _ l r) = go (go z' l) r
{-# INLINE foldl' #-}

{--------------------------------------------------------------------
  List variations 
--------------------------------------------------------------------}
-- | /O(n)/. The elements of a set. (For sets, this is equivalent to toList)
elems :: IntSet -> [Int]
elems s
  = toList s

{--------------------------------------------------------------------
  Lists 
--------------------------------------------------------------------}
-- | /O(n)/. Convert the set to a list of elements.
toList :: IntSet -> [Int]
toList t
  = fold (:) [] t

-- | /O(n)/. Convert the set to an ascending list of elements.
toAscList :: IntSet -> [Int]
toAscList t = toList t

-- | /O(n*min(n,W))/. Create a set from a list of integers.
fromList :: [Int] -> IntSet
fromList xs
  = foldlStrict ins empty xs
  where
    ins t x  = insert x t

-- | /O(n)/. Build a set from an ascending list of elements.
-- /The precondition (input list is ascending) is not checked./
fromAscList :: [Int] -> IntSet 
fromAscList [] = Nil
fromAscList (x0 : xs0) = fromDistinctAscList (combineEq x0 xs0)
  where 
    combineEq x' [] = [x']
    combineEq x' (x:xs) 
      | x==x'     = combineEq x' xs
      | otherwise = x' : combineEq x xs

-- | /O(n)/. Build a set from an ascending list of distinct elements.
-- /The precondition (input list is strictly ascending) is not checked./
fromDistinctAscList :: [Int] -> IntSet
fromDistinctAscList []         = Nil
fromDistinctAscList (z0 : zs0) = work z0 zs0 Nada
  where
    work x []     stk = finish x (Tip x) stk
    work x (z:zs) stk = reduce z zs (branchMask z x) x (Tip x) stk

    reduce z zs _ px tx Nada = work z zs (Push px tx Nada)
    reduce z zs m px tx stk@(Push py ty stk') =
        let mxy = branchMask px py
            pxy = mask px mxy
        in  if shorter m mxy
                 then reduce z zs m pxy (Bin pxy mxy ty tx) stk'
                 else work z zs (Push px tx stk)

    finish _  t  Nada = t
    finish px tx (Push py ty stk) = finish p (join py ty px tx) stk
        where m = branchMask px py
              p = mask px m

data Stack = Push {-# UNPACK #-} !Prefix !IntSet !Stack | Nada


{--------------------------------------------------------------------
  Eq 
--------------------------------------------------------------------}
instance Eq IntSet where
  t1 == t2  = equal t1 t2
  t1 /= t2  = nequal t1 t2

equal :: IntSet -> IntSet -> Bool
equal (Bin p1 m1 l1 r1) (Bin p2 m2 l2 r2)
  = (m1 == m2) && (p1 == p2) && (equal l1 l2) && (equal r1 r2) 
equal (Tip x) (Tip y)
  = (x==y)
equal Nil Nil = True
equal _   _   = False

nequal :: IntSet -> IntSet -> Bool
nequal (Bin p1 m1 l1 r1) (Bin p2 m2 l2 r2)
  = (m1 /= m2) || (p1 /= p2) || (nequal l1 l2) || (nequal r1 r2) 
nequal (Tip x) (Tip y)
  = (x/=y)
nequal Nil Nil = False
nequal _   _   = True

{--------------------------------------------------------------------
  Ord 
--------------------------------------------------------------------}

instance Ord IntSet where
    compare s1 s2 = compare (toAscList s1) (toAscList s2) 
    -- tentative implementation. See if more efficient exists.

{--------------------------------------------------------------------
  Show
--------------------------------------------------------------------}
instance Show IntSet where
  showsPrec p xs = showParen (p > 10) $
    showString "fromList " . shows (toList xs)

{-
XXX unused code
showSet :: [Int] -> ShowS
showSet []     
  = showString "{}" 
showSet (x:xs) 
  = showChar '{' . shows x . showTail xs
  where
    showTail []     = showChar '}'
    showTail (x':xs') = showChar ',' . shows x' . showTail xs'
-}

{--------------------------------------------------------------------
  Read
--------------------------------------------------------------------}
instance Read IntSet where
#ifdef __GLASGOW_HASKELL__
  readPrec = parens $ prec 10 $ do
    Ident "fromList" <- lexP
    xs <- readPrec
    return (fromList xs)

  readListPrec = readListPrecDefault
#else
  readsPrec p = readParen (p > 10) $ \ r -> do
    ("fromList",s) <- lex r
    (xs,t) <- reads s
    return (fromList xs,t)
#endif

{--------------------------------------------------------------------
  Typeable
--------------------------------------------------------------------}

#include "Typeable.h"
INSTANCE_TYPEABLE0(IntSet,intSetTc,"IntSet")

{--------------------------------------------------------------------
  NFData
--------------------------------------------------------------------}

-- The IntSet constructors consist only of strict fields of Ints and
-- IntSets, thus the default NFData instance which evaluates to whnf
-- should suffice
instance NFData IntSet

{--------------------------------------------------------------------
  Debugging
--------------------------------------------------------------------}
-- | /O(n)/. Show the tree that implements the set. The tree is shown
-- in a compressed, hanging format.
showTree :: IntSet -> String
showTree s
  = showTreeWith True False s


{- | /O(n)/. The expression (@'showTreeWith' hang wide map@) shows
 the tree that implements the set. If @hang@ is
 'True', a /hanging/ tree is shown otherwise a rotated tree is shown. If
 @wide@ is 'True', an extra wide version is shown.
-}
showTreeWith :: Bool -> Bool -> IntSet -> String
showTreeWith hang wide t
  | hang      = (showsTreeHang wide [] t) ""
  | otherwise = (showsTree wide [] [] t) ""

showsTree :: Bool -> [String] -> [String] -> IntSet -> ShowS
showsTree wide lbars rbars t
  = case t of
      Bin p m l r
          -> showsTree wide (withBar rbars) (withEmpty rbars) r .
             showWide wide rbars .
             showsBars lbars . showString (showBin p m) . showString "\n" .
             showWide wide lbars .
             showsTree wide (withEmpty lbars) (withBar lbars) l
      Tip x
          -> showsBars lbars . showString " " . shows x . showString "\n" 
      Nil -> showsBars lbars . showString "|\n"

showsTreeHang :: Bool -> [String] -> IntSet -> ShowS
showsTreeHang wide bars t
  = case t of
      Bin p m l r
          -> showsBars bars . showString (showBin p m) . showString "\n" . 
             showWide wide bars .
             showsTreeHang wide (withBar bars) l .
             showWide wide bars .
             showsTreeHang wide (withEmpty bars) r
      Tip x
          -> showsBars bars . showString " " . shows x . showString "\n" 
      Nil -> showsBars bars . showString "|\n" 

showBin :: Prefix -> Mask -> String
showBin _ _
  = "*" -- ++ show (p,m)

showWide :: Bool -> [String] -> String -> String
showWide wide bars 
  | wide      = showString (concat (reverse bars)) . showString "|\n" 
  | otherwise = id

showsBars :: [String] -> ShowS
showsBars bars
  = case bars of
      [] -> id
      _  -> showString (concat (reverse (tail bars))) . showString node

node :: String
node           = "+--"

withBar, withEmpty :: [String] -> [String]
withBar bars   = "|  ":bars
withEmpty bars = "   ":bars


{--------------------------------------------------------------------
  Helpers
--------------------------------------------------------------------}
{--------------------------------------------------------------------
  Join
--------------------------------------------------------------------}
join :: Prefix -> IntSet -> Prefix -> IntSet -> IntSet
join p1 t1 p2 t2
  | zero p1 m = Bin p m t1 t2
  | otherwise = Bin p m t2 t1
  where
    m = branchMask p1 p2
    p = mask p1 m
{-# INLINE join #-}

{--------------------------------------------------------------------
  @bin@ assures that we never have empty trees within a tree.
--------------------------------------------------------------------}
bin :: Prefix -> Mask -> IntSet -> IntSet -> IntSet
bin _ _ l Nil = l
bin _ _ Nil r = r
bin p m l r   = Bin p m l r
{-# INLINE bin #-}

  
{--------------------------------------------------------------------
  Endian independent bit twiddling
--------------------------------------------------------------------}
zero :: Int -> Mask -> Bool
zero i m
  = (natFromInt i) .&. (natFromInt m) == 0
{-# INLINE zero #-}

nomatch,match :: Int -> Prefix -> Mask -> Bool
nomatch i p m
  = (mask i m) /= p
{-# INLINE nomatch #-}

match i p m
  = (mask i m) == p
{-# INLINE match #-}

-- Suppose a is largest such that 2^a divides 2*m.
-- Then mask i m is i with the low a bits zeroed out.
mask :: Int -> Mask -> Prefix
mask i m
  = maskW (natFromInt i) (natFromInt m)
{-# INLINE mask #-}

{--------------------------------------------------------------------
  Big endian operations  
--------------------------------------------------------------------}
maskW :: Nat -> Nat -> Prefix
maskW i m
  = intFromNat (i .&. (complement (m-1) `xor` m))
{-# INLINE maskW #-}

shorter :: Mask -> Mask -> Bool
shorter m1 m2
  = (natFromInt m1) > (natFromInt m2)
{-# INLINE shorter #-}

branchMask :: Prefix -> Prefix -> Mask
branchMask p1 p2
  = intFromNat (highestBitMask (natFromInt p1 `xor` natFromInt p2))
{-# INLINE branchMask #-}

{----------------------------------------------------------------------
  Finding the highest bit (mask) in a word [x] can be done efficiently in
  three ways:
  * convert to a floating point value and the mantissa tells us the 
    [log2(x)] that corresponds with the highest bit position. The mantissa 
    is retrieved either via the standard C function [frexp] or by some bit 
    twiddling on IEEE compatible numbers (float). Note that one needs to 
    use at least [double] precision for an accurate mantissa of 32 bit 
    numbers.
  * use bit twiddling, a logarithmic sequence of bitwise or's and shifts (bit).
  * use processor specific assembler instruction (asm).

  The most portable way would be [bit], but is it efficient enough?
  I have measured the cycle counts of the different methods on an AMD 
  Athlon-XP 1800 (~ Pentium III 1.8Ghz) using the RDTSC instruction:

  highestBitMask: method  cycles
                  --------------
                   frexp   200
                   float    33
                   bit      11
                   asm      12

  highestBit:     method  cycles
                  --------------
                   frexp   195
                   float    33
                   bit      11
                   asm      11

  Wow, the bit twiddling is on today's RISC like machines even faster
  than a single CISC instruction (BSR)!
----------------------------------------------------------------------}

{----------------------------------------------------------------------
  [highestBitMask] returns a word where only the highest bit is set.
  It is found by first setting all bits in lower positions than the 
  highest bit and than taking an exclusive or with the original value.
  Allthough the function may look expensive, GHC compiles this into
  excellent C code that subsequently compiled into highly efficient
  machine code. The algorithm is derived from Jorg Arndt's FXT library.
----------------------------------------------------------------------}
highestBitMask :: Nat -> Nat
highestBitMask x0
  = case (x0 .|. shiftRL x0 1) of
     x1 -> case (x1 .|. shiftRL x1 2) of
      x2 -> case (x2 .|. shiftRL x2 4) of
       x3 -> case (x3 .|. shiftRL x3 8) of
        x4 -> case (x4 .|. shiftRL x4 16) of
         x5 -> case (x5 .|. shiftRL x5 32) of   -- for 64 bit platforms
          x6 -> (x6 `xor` (shiftRL x6 1))
{-# INLINE highestBitMask #-}


{--------------------------------------------------------------------
  Utilities 
--------------------------------------------------------------------}
foldlStrict :: (a -> b -> a) -> a -> [b] -> a
foldlStrict f = go
  where
    go z []     = z
    go z (x:xs) = let z' = f z x in z' `seq` go z' xs
{-# INLINE foldlStrict #-}