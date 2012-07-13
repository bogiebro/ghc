%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[NewDemand]{@NewDemand@: A decoupled implementation of a demand domain}

\begin{code}

module NewDemand (
        LatticeLike, top, bot, lub, both, pre,
        StrDmd(..), strBot, strTop, strStr, strProd, strCall,
        AbsDmd(..), absBot, absTop, absProd,
        Demand, JointDmd(..), mkJointDmd, isTop, isAbs,
	DmdType(..), topDmdType, botDmdType, mkDmdType, mkTopDmdType, 
		dmdTypeDepth, 
	DmdEnv, emptyDmdEnv,
	DmdResult(..), isBotRes, isTopRes, resTypeArgDmd, topRes, botRes, cprRes,
        appIsBottom, isBottomingSig, pprIfaceStrictSig, returnsCPR, 
	StrictSig(..), mkStrictSig, topSig, botSig, cprSig,
        isTopSig, splitStrictSig, increaseStrictSigArity,
       
        seqStrDmd, seqStrDmdList, seqAbsDmd, seqAbsDmdList,
        seqDemand, seqDemandList, seqDmdType, seqStrictSig, 
        evalDmd, vanillaCall, isStrictDmd, splitCallDmd, splitDmdTy,
        defer, deferType, deferEnv, isPolyDmd, replicateDmd, splitProdDmd,

     ) where

#include "HsVersions.h"

import StaticFlags
import Outputable
import VarEnv
import UniqFM
import Util
import BasicTypes
import Binary

{-! for StrDmd derive: Binary !-}
{-! for AbsDmd derive: Binary !-}
{-! for Demand derive: Binary !-}
{-! for DmdResult derive: Binary !-}
{-! for DmdType derive: Binary !-}
{-! for StrictSig derive: Binary !-}

\end{code}

%************************************************************************
%*									*
\subsection{Lattice-like structure for domains}
%*									*
%************************************************************************

\begin{code}

class LatticeLike a where
  bot    :: a
  top    :: a
  pre    :: a -> a -> Bool
  lub    :: a -> a -> a 
  both   :: a -> a -> a

-- False < True
instance LatticeLike Bool where
  bot     = False
  top     = True
-- x `pre` y <==> (x => y)
  pre x y = (not x) || y  
  lub     = (||)
  both    = (&&)

\end{code}


%************************************************************************
%*									*
\subsection{Strictness domain}
%*									*
%************************************************************************

\begin{code}

-- Vanilla strictness domain
data StrDmd
  = HyperStr             -- Hyper-strict 
  | Lazy                 -- Lazy
  | Call StrDmd          -- Call demand
  | Str                  -- Head-Strict
  | SProd [StrDmd]       -- Possibly deferred roduct or function demand
  deriving ( Eq, Show )

-- Well-formedness preserving constructors for the Strictness domain
strBot, strTop, strStr :: StrDmd
strBot     = HyperStr
strTop     = Lazy
strStr     = Str

strCall :: StrDmd -> StrDmd
strCall s  = case s of 
               Lazy     -> Lazy
               HyperStr -> HyperStr
               _        -> Call s

strProd :: [StrDmd] -> StrDmd
strProd sx
  | all (== Lazy) sx        = strStr
  | any (== HyperStr) sx    = strTop
  | otherwise               = SProd sx

-- Pretty-printing
instance Outputable StrDmd where
  ppr HyperStr      = char 'B'
  ppr Lazy          = char 'L'
  ppr (Call s)      = char 'C' <> parens (ppr s)
  ppr Str           = char 'S'
  ppr (SProd sx)    = char 'S' <> parens (hcat (map ppr sx))

-- LatticeLike implementation for strictness demands
instance LatticeLike StrDmd where
  bot = HyperStr
  top = Lazy
  
  pre _ Lazy                               = True
  pre HyperStr _                           = True
  pre (Call s1) (Call s2)                  = pre s1 s2
  pre (Call _) Str                         = True
  pre (SProd _) Str                        = True
  pre (SProd sx1) (SProd sx2)    
            | length sx1 == length sx2     = all (== True) $ zipWith pre sx1 sx2 
  pre x y                                  = x == y

  lub x y | x == y                         = x 
  lub y x | x `pre` y                      = lub x y
  lub HyperStr s                           = s
  lub _ Lazy                               = strTop
  lub (SProd _) Str                        = strStr
  lub (SProd sx1) (SProd sx2) 
           | length sx1 == length sx2      = strProd $ zipWith lub sx1 sx2
           | otherwise                     = strStr
  lub (Call s1) (Call s2)                  = Call (s1 `lub` s2)
  lub (Call _)  Str                        = strStr
  lub _ _                                  = strTop

  both x y | x == y                        = x 
  both y x | x `pre` y                     = both x y
  both HyperStr _                          = strBot
  both s Lazy                              = s
  both s@(SProd _) Str                     = s
  both (SProd sx1) (SProd sx2) 
           | length sx1 == length sx2      = strProd $ zipWith both sx1 sx2 
  both (Call s1) (Call s2)                 = Call (s1 `both` s2)
  both s@(Call _)  Str                     = s
  both _ _                                 = strBot

-- utility functions to deal with memory leaks
seqStrDmd :: StrDmd -> ()
seqStrDmd (SProd ds)   = seqStrDmdList ds
seqStrDmd (Call s)     = s `seq` () 
seqStrDmd _            = ()

seqStrDmdList :: [StrDmd] -> ()
seqStrDmdList [] = ()
seqStrDmdList (d:ds) = seqStrDmd d `seq` seqStrDmdList ds

-- Serialization
instance Binary StrDmd where
  put_ bh HyperStr     = do putByte bh 0
  put_ bh Lazy         = do putByte bh 1
  put_ bh Str          = do putByte bh 2
  put_ bh (Call s)     = do putByte bh 3
                            put_ bh s
  put_ bh (SProd sx)   = do putByte bh 4
                            put_ bh sx  
  get bh = do 
         h <- getByte bh
         case h of
           0 -> do return strBot
           1 -> do return strTop
           2 -> do return strStr
           3 -> do s  <- get bh
                   return $ strCall s
           _ -> do sx <- get bh
                   return $ strProd sx

-- Splitting polymorphic demands
replicateStrDmd :: Int -> StrDmd -> [StrDmd]
replicateStrDmd n Lazy         = replicate n Lazy
replicateStrDmd n HyperStr     = replicate n HyperStr
replicateStrDmd n Str          = replicate n Lazy
replicateStrDmd _ d            = pprPanic "replicateStrDmd" (ppr d)          

isPolyStrDmd :: StrDmd -> Bool
isPolyStrDmd Lazy     = True
isPolyStrDmd HyperStr = True
isPolyStrDmd Str      = True
isPolyStrDmd _        = False

\end{code}

%************************************************************************
%*									*
\subsection{Absence domain}
%*									*
%************************************************************************

\begin{code}

data AbsDmd
  = Abs                  -- Defenitely unused
  | Used                 -- May be used
  | UHead                -- U(A...A)
  | UProd [AbsDmd]       -- Product
  deriving ( Eq, Show )


-- Pretty-printing
instance Outputable AbsDmd where
  ppr Abs         = char 'A'
  ppr Used        = char 'U'
  ppr UHead       = char 'H'
  ppr (UProd as)  = (char 'U') <> parens (hcat (map ppr as))

-- Well-formedness preserving constructors for the Absence domain
absBot, absTop, absHead :: AbsDmd
absBot     = Abs
absHead    = UHead
absTop     = Used

absProd :: [AbsDmd] -> AbsDmd
absProd ux 
  | all (== Used) ux   = Used
  | all (== Abs) ux    = UHead
  | otherwise          = UProd ux


instance LatticeLike AbsDmd where
  bot                            = absBot
  top                            = absTop
 
  pre Abs _                      = True
  pre _ Used                     = True
  pre UHead (UProd _)            = True
  pre (UProd ux1) (UProd ux2)
     | length ux1 == length ux2  = all (== True) $ zipWith pre ux1 ux2 
  pre x y                        = x == y

  lub x y | x == y               = x 
  lub y x | x `pre` y            = lub x y
  lub Abs a                      = a
  lub _ Used                     = absTop
  lub UHead u@(UProd _)          = u
  lub (UProd ux1) (UProd ux2)
     | length ux1 == length ux2  = absProd $ zipWith lub ux1 ux2
  lub _ _                        = absTop

  both                           = lub

-- utility functions
seqAbsDmd :: AbsDmd -> ()
seqAbsDmd (UProd ds) = seqAbsDmdList ds
seqAbsDmd _          = ()

seqAbsDmdList :: [AbsDmd] -> ()
seqAbsDmdList [] = ()
seqAbsDmdList (d:ds) = seqAbsDmd d `seq` seqAbsDmdList ds

-- Serialization
instance Binary AbsDmd where
    put_ bh Abs         = do 
            putByte bh 0
    put_ bh Used        = do 
            putByte bh 1
    put_ bh UHead       = do 
            putByte bh 2
    put_ bh (UProd ux) = do
            putByte bh 3
            put_ bh ux

    get  bh = do
            h <- getByte bh
            case h of 
              0 -> return absBot       
              1 -> return absTop
              2 -> return absHead
              _ -> do ux <- get bh
                      return $ absProd ux

-- Splitting polymorphic demands
replicateAbsDmd :: Int -> AbsDmd -> [AbsDmd]
replicateAbsDmd n Abs          = replicate n Abs
replicateAbsDmd n Used         = replicate n Used
replicateAbsDmd n UHead        = replicate n Abs
replicateAbsDmd _ d            = pprPanic "replicateAbsDmd" (ppr d)          

isPolyAbsDmd :: AbsDmd -> Bool
isPolyAbsDmd Abs      = True
isPolyAbsDmd Used     = True
isPolyAbsDmd UHead    = True
isPolyAbsDmd _        = False

\end{code}
  
%************************************************************************
%*									*
\subsection{Joint domain for Strictness and Absence}
%*									*
%************************************************************************

\begin{code}

data JointDmd = JD { str :: StrDmd, abs :: AbsDmd } 
  deriving ( Eq, Show )

-- Pretty-printing
instance Outputable JointDmd where
  ppr (JD s a) = angleBrackets (ppr s <> char ',' <> ppr a)

-- Well-formedness preserving constructors for the joint domain
mkJointDmd :: StrDmd -> AbsDmd -> JointDmd
mkJointDmd s a 
 = case (s, a) of 
     (HyperStr, UProd _) -> JD HyperStr Used
     _                   -> JD s a
     
instance LatticeLike JointDmd where
  bot                        = mkJointDmd bot bot
  top                        = mkJointDmd top top

  pre x _ | x == bot         = True
  pre _ x | x == top         = True
  pre (JD s1 a1) (JD s2 a2)  = (pre s1 s2) && (pre a1 a2)

  lub  (JD s1 a1) (JD s2 a2) = mkJointDmd (lub s1 s2)  $ lub a1 a2            
  both (JD s1 a1) (JD s2 a2) = mkJointDmd (both s1 s2) $ both a1 a2            

isTop :: JointDmd -> Bool
isTop (JD s a) | s == top && a == top = True
isTop _                               = False 

isAbs :: JointDmd -> Bool
isAbs (JD s a) | s == top && a == bot = True
isAbs _                               = False 


-- More utility functions for strictness
seqDemand :: JointDmd -> ()
seqDemand (JD x y) = x `seq` y `seq` ()

seqDemandList :: [JointDmd] -> ()
seqDemandList [] = ()
seqDemandList (d:ds) = seqDemand d `seq` seqDemandList ds

-- Serialization
instance Binary JointDmd where
    put_ bh (JD x y) = do put_ bh x; put_ bh y
    get  bh = do 
              x <- get bh
              y <- get bh
              return $ mkJointDmd x y

isStrictDmd :: Demand -> Bool
isStrictDmd (JD x _) = x /= top

evalDmd :: JointDmd
evalDmd = mkJointDmd strStr absTop

splitCallDmd :: JointDmd -> (Int, JointDmd)
splitCallDmd (JD (Call d) a) 
  = case splitCallDmd (JD d a) of
      (n, r) -> (n + 1, r)
splitCallDmd d	      = (0, d)

vanillaCall :: Arity -> Demand
vanillaCall 0 = evalDmd
vanillaCall n =
  -- generate S^n (S)  
  let strComp = (iterate strCall strStr) !! n
   in mkJointDmd strComp absTop

defer :: Demand -> Demand
defer (JD _ a) = (JD bot a)

\end{code}

Note [Replicating polymorphic demands]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Some demands can be considered as polymorphic. Generally, it is
applicable to such beasts as tops, bottoms as well as Head-Used adn
Head-stricts demands. For instance,

S ~ S(L, ..., L)

Also, when top or bottom is occurred as a result demand, it in fact
can be expanded to saturate a callee's arity. 


\begin{code}

-- Replicating polymorphic demands
replicateDmd :: Int -> Demand -> [Demand]
replicateDmd _ d
  | not $ isPolyDmd d   = pprPanic "replicateDmd" (ppr d)          
replicateDmd n (JD x y) = zipWith JD (replicateStrDmd n x) 
                                     (replicateAbsDmd n y)

isPolyDmd :: Demand -> Bool
isPolyDmd (JD a b) = isPolyStrDmd a && isPolyAbsDmd b

-- Split a product to parameteres
splitProdDmd :: Demand -> [Demand]
splitProdDmd (JD (SProd sx) (UProd ux))
  = ASSERT( sx `lengthIs` (length ux) ) zipWith JD sx ux
splitProdDmd (JD (SProd sx) u) 
  | isPolyAbsDmd u  
  =  zipWith JD sx (replicateAbsDmd (length sx) u)
splitProdDmd (JD s (UProd ux))
  | isPolyStrDmd s  
  =  zipWith JD (replicateStrDmd (length ux) s) ux
splitProdDmd d = pprPanic "splitProdDmd" (ppr d)

\end{code}

%************************************************************************
%*									*
\subsection{Demand results}
%*									*
%************************************************************************

\begin{code}

------------------------------------------------------------------------
-- Pure demand result                                             
------------------------------------------------------------------------

data PureResult = TopRes	-- Nothing known, assumed to be just lazy
                | BotRes        -- Diverges or errors
 	       deriving( Eq, Show )

instance LatticeLike PureResult where
     bot = BotRes
     top = TopRes
     pre x y = (x == y) || (y == top)
     lub x y | x == y = x 
     lub _ _          = top
     both x y | x == y = x 
     both _ _          = bot

instance Binary PureResult where
    put_ bh BotRes       = do putByte bh 0
    put_ bh TopRes       = do putByte bh 1

    get  bh = do
            h <- getByte bh
            case h of 
              0 -> return bot       
              _ -> return top


------------------------------------------------------------------------
-- Constructed Product Result                                             
------------------------------------------------------------------------

data CPRResult = NoCPR
               | RetCPR
               deriving( Eq, Show )

instance LatticeLike CPRResult where
     bot = RetCPR
     top = NoCPR
     pre x y = (x == y) || (y == top)
     lub x y | x == y  = x 
     lub _ _           = top
     both x y | x == y = x 
     both _ _          = bot

instance Binary CPRResult where
    put_ bh RetCPR       = do putByte bh 0
    put_ bh NoCPR        = do putByte bh 1

    get  bh = do
            h <- getByte bh
            case h of 
              0 -> return bot       
              _ -> return top

------------------------------------------------------------------------
-- Combined demand result                                             --
------------------------------------------------------------------------

data DmdResult = DR { res :: PureResult, cpr :: CPRResult }
     deriving ( Eq )

instance LatticeLike DmdResult where
  bot                        = topRes
  top                        = botRes

  pre x _ | x == bot         = True
  pre _ x | x == top         = True
  pre (DR s1 a1) (DR s2 a2)  = (pre s1 s2) && (pre a1 a2)

  lub  (DR s1 a1) (DR s2 a2) = mkDmdResult (lub s1 s2)  $ lub a1 a2            
  both (DR s1 a1) (DR s2 a2) = mkDmdResult (both s1 s2) $ both a1 a2            

-- Pretty-printing
instance Outputable DmdResult where
  ppr (DR TopRes RetCPR) = char 'm'   --    DDDr without ambiguity
  ppr (DR BotRes _) = char 'b'   
  ppr _ = empty	  -- Keep these distinct from Demand letters

instance Binary DmdResult where
    put_ bh (DR x y) = do put_ bh x; put_ bh y
    get  bh = do 
              x <- get bh
              y <- get bh
              return $ mkDmdResult x y

mkDmdResult :: PureResult -> CPRResult -> DmdResult
mkDmdResult BotRes NoCPR = topRes
mkDmdResult x y = DR x y

seqDmdResult :: DmdResult -> ()
seqDmdResult (DR x y) = x `seq` y `seq` ()

-- [cprRes] lets us switch off CPR analysis
-- by making sure that everything uses TopRes instead of RetCPR
-- Assuming, of course, that they don't mention RetCPR by name.
-- They should onlyu use retCPR
topRes, botRes, cprRes :: DmdResult
topRes = DR TopRes NoCPR
botRes = DR BotRes RetCPR
cprRes | opt_CprOff = DR TopRes NoCPR
       | otherwise  = DR TopRes RetCPR

isTopRes :: DmdResult -> Bool
isTopRes (DR TopRes NoCPR)  = True
isTopRes _                  = False

isBotRes :: DmdResult -> Bool
isBotRes (DR BotRes RetCPR) = True
isBotRes _                  = False

returnsCPR :: DmdResult -> Bool
returnsCPR (DR TopRes RetCPR) = True
returnsCPR _      = False

resTypeArgDmd :: DmdResult -> Demand
-- TopRes and BotRes are polymorphic, so that
--	BotRes === Bot -> BotRes === ...
--	TopRes === Top -> TopRes === ...
-- This function makes that concrete
resTypeArgDmd r | isBotRes r = bot
resTypeArgDmd _              = top

\end{code}

%************************************************************************
%*									*
\subsection{Demand environments and types}
%*									*
%************************************************************************

\begin{code}


type Demand = JointDmd

type DmdEnv = VarEnv Demand

data DmdType = DmdType 
		  DmdEnv	-- Demand on explicitly-mentioned 
		       	        --	free variables
		  [Demand]	-- Demand on arguments
		  DmdResult	-- Nature of result
\end{code}

Note [Nature of result demand]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We assume the result in a demand type to be either a top or bottom
in order to represent the information about demand on the function
result, imposed by its definition. There are not so many things we 
can say, though. 

For instance, one can consider a function

        h = \v -> error "urk"

Taking the definition of strictness, we can easily see that 

        h undefined = undefined

that is, h is strict in v. However, v is not used somehow in the body
of h How can we know that h is strict in v? In fact, we know it by
considering a result demand of error and bottom and unleashing it on
all the variables in scope at a call site (in this case, this is only
v). We can also consider a case

       h = \v -> f x

where we know that the result of f is not hyper-strict (i.e, it is
lazy, or top). So, we put the same demand on v, which allow us to
infer a lazy demand that h puts on v.


\begin{code}
-- Equality needed for fixpoints in DmdAnal
instance Eq DmdType where
  (==) (DmdType fv1 ds1 res1)
       (DmdType fv2 ds2 res2) =  ufmToList fv1 == ufmToList fv2
			      && ds1 == ds2 && res1 == res2

instance Outputable DmdType where
  ppr (DmdType fv ds res) 
    = hsep [text "DmdType",
	    hcat (map ppr ds) <> ppr res,
	    if null fv_elts then empty
	    else braces (fsep (map pp_elt fv_elts))]
    where
      pp_elt (uniq, dmd) = ppr uniq <> text "->" <> ppr dmd
      fv_elts = ufmToList fv

instance Binary DmdType where
  -- Ignore DmdEnv when spitting out the DmdType
  put_ bh (DmdType _ ds dr) 
       = do put_ bh ds 
            put_ bh dr
  get bh 
      = do ds <- get bh 
           dr <- get bh 
           return (DmdType emptyDmdEnv ds dr)

emptyDmdEnv :: VarEnv Demand
emptyDmdEnv = emptyVarEnv

topDmdType, botDmdType, cprDmdType :: DmdType
topDmdType = DmdType emptyDmdEnv [] topRes
botDmdType = DmdType emptyDmdEnv [] botRes
cprDmdType = DmdType emptyDmdEnv [] cprRes

isTopDmdType :: DmdType -> Bool
-- Only used on top-level types, hence the assert
isTopDmdType (DmdType env [] res)
             | isTopRes res          = ASSERT( isEmptyVarEnv env) True	
isTopDmdType _                       = False

mkDmdType :: DmdEnv -> [Demand] -> DmdResult -> DmdType
mkDmdType fv ds res = DmdType fv ds res

mkTopDmdType :: [Demand] -> DmdResult -> DmdType
mkTopDmdType ds res = DmdType emptyDmdEnv ds res

dmdTypeDepth :: DmdType -> Arity
dmdTypeDepth (DmdType _ ds _) = length ds

seqDmdType :: DmdType -> ()
seqDmdType (DmdType _env ds res) = 
  {- ??? env `seq` -} seqDemandList ds `seq` seqDmdResult res `seq` ()

splitDmdTy :: DmdType -> (Demand, DmdType)
-- Split off one function argument
-- We already have a suitable demand on all
-- free vars, so no need to add more!
splitDmdTy (DmdType fv (dmd:dmds) res_ty) = (dmd, DmdType fv dmds res_ty)
splitDmdTy ty@(DmdType _ [] res_ty)       = (resTypeArgDmd res_ty, ty)

deferType :: DmdType -> DmdType
deferType (DmdType fv _ _) = DmdType (deferEnv fv) [] top

deferEnv :: DmdEnv -> DmdEnv
deferEnv fv = mapVarEnv defer fv
\end{code}

%************************************************************************
%*									*
\subsection{Demand signature}
%*									*
%************************************************************************

In a let-bound Id we record its strictness info.  
In principle, this strictness info is a demand transformer, mapping
a demand on the Id into a DmdType, which gives
	a) the free vars of the Id's value
	b) the Id's arguments
	c) an indication of the result of applying 
	   the Id to its arguments

However, in fact we store in the Id an extremely emascuated demand transfomer,
namely 
		a single DmdType
(Nevertheless we dignify StrictSig as a distinct type.)

This DmdType gives the demands unleashed by the Id when it is applied
to as many arguments as are given in by the arg demands in the DmdType.

If an Id is applied to less arguments than its arity, it means that
the demand on the function at a call site is weaker than the vanilla
call demand, used for signature inference. Therefore we place a top
demand on all arguments. Otherwise, the demand is specified by Id's
signature.

For example, the demand transformer described by the DmdType
		DmdType {x -> <S(LL),U(UU)>} [V,A] Top
says that when the function is applied to two arguments, it
unleashes demand <S(LL),U(UU)> on the free var x, V on the first arg,
and A on the second.  

If this same function is applied to one arg, all we can say is that it
uses x with <L,U>, and its arg with demand <L,U>.

\begin{code}
newtype StrictSig = StrictSig DmdType
		  deriving( Eq )

instance Outputable StrictSig where
   ppr (StrictSig ty) = ppr ty

mkStrictSig :: DmdType -> StrictSig
mkStrictSig dmd_ty = StrictSig dmd_ty

splitStrictSig :: StrictSig -> ([Demand], DmdResult)
splitStrictSig (StrictSig (DmdType _ dmds res)) = (dmds, res)

increaseStrictSigArity :: Int -> StrictSig -> StrictSig
-- Add extra arguments to a strictness signature
increaseStrictSigArity arity_increase (StrictSig (DmdType env dmds res))
  = StrictSig (DmdType env (replicate arity_increase top ++ dmds) res)

isTopSig :: StrictSig -> Bool
isTopSig (StrictSig ty) = isTopDmdType ty

topSig, botSig, cprSig:: StrictSig
topSig = StrictSig topDmdType
botSig = StrictSig botDmdType
cprSig = StrictSig cprDmdType

-- Serialization
instance Binary StrictSig where
    put_ bh (StrictSig aa) = do
            put_ bh aa
    get bh = do
          aa <- get bh
          return (StrictSig aa)
	
\end{code}

Note [Non-full application] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~ 

If a function having bottom as its demand result is applied to a less
number of arguments than its syntactic arity, we cannot say for sure
that it is going to diverge. This is the reason why we use the
function appIsBottom, which, given a strictness signature and a number
of arguments, says conservatively if the function is going to diverge
or not.

\begin{code}

-- appIsBottom returns true if an application to n args would diverge
appIsBottom :: StrictSig -> Int -> Bool
appIsBottom (StrictSig (DmdType _ ds res)) n
            | isBotRes res                      = not $ lengthExceeds ds n 
appIsBottom _				      _ = False

isBottomingSig :: StrictSig -> Bool
isBottomingSig (StrictSig (DmdType _ _ res))    
               | isBotRes res                   = True
isBottomingSig _				= False

seqStrictSig :: StrictSig -> ()
seqStrictSig (StrictSig ty) = seqDmdType ty

-- Used for printing top-level strictness pragmas in interface files
pprIfaceStrictSig :: StrictSig -> SDoc
pprIfaceStrictSig (StrictSig (DmdType _ dmds res))
  = hcat (map ppr dmds) <> ppr res
\end{code}
