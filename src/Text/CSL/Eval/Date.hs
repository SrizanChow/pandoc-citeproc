{-# LANGUAGE PatternGuards #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Text.CSL.Eval.Date
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Andrea Rossato <andrea.rossato@unitn.it>
-- Stability   :  unstable
-- Portability :  unportable
--
-- The CSL implementation
--
-----------------------------------------------------------------------------

module Text.CSL.Eval.Date where

import Control.Monad.State
import qualified Control.Exception as E

import Data.List
import Data.List.Split

import Text.CSL.Exception
import Text.CSL.Eval.Common
import Text.CSL.Eval.Output
import Text.CSL.Style
import Text.CSL.Reference
import Text.CSL.Util ( readNum, toRead, last')
import Text.Pandoc.Definition ( Inline (Str) )

evalDate :: Element -> State EvalState [Output]
evalDate (Date s f fm dl dp dp') = do
  tm <- gets $ terms . env
  k  <- getStringVar "ref-id"
  em <- gets mode
  let updateFM (Formatting aa ab ac ad ae af ag ah ai aj ak al am an ahl)
               (Formatting _  _  bc bd be bf bg bh _  bj bk _ _ _ _) =
                   Formatting aa ab (updateS ac bc)
                                    (updateS ad bd)
                                    (updateS ae be)
                                    (updateS af bf)
                                    (updateS ag bg)
                                    (updateS ah bh)
                                    ai
                                    (updateS aj bj)
                                    (if bk /= ak then bk else ak)
                                    al am an ahl
      updateS a b = if b /= a && b /= [] then b else a
  case f of
    NoFormDate -> mapM getDateVar s >>= return . outputList fm dl .
                  concatMap (formatDate em k tm dp)
    _          -> do Date _ _ lfm ldl ldp _ <- getDate f
                     let go dps = return . outputList (updateFM fm lfm) (if ldl /= [] then ldl else dl) .
                                  concatMap (formatDate em k tm dps)
                         update l x@(DatePart a b c d) =
                             case filter ((==) a . dpName) l of
                               (DatePart _ b' c' d':_) -> DatePart a (updateS  b b')
                                                                     (updateS  c c')
                                                                     (updateFM d d')
                               _                       -> x
                         updateDP = map (update dp) ldp
                         date     = mapM getDateVar s
                     case dp' of
                       "year-month" -> go (filter ((/=) "day"  . dpName) updateDP) =<< date
                       "year"       -> go (filter ((==) "year" . dpName) updateDP) =<< date
                       _            -> go                                updateDP  =<< date

evalDate _ = return []

getDate :: DateForm -> State EvalState Element
getDate f = do
  x <- filter (\(Date _ df _ _ _ _) -> df == f) <$> gets (dates . env)
  case x of
    [x'] -> return x'
    _    -> return $ Date [] NoFormDate emptyFormatting [] [] []

formatDate :: EvalMode -> String -> [CslTerm] -> [DatePart] -> [RefDate] -> [Output]
formatDate em k tm dp date
    | [d]     <- date = concatMap (formatDatePart d) dp
    | (a:b:_) <- date = addODate . concat $ doRange a b
    | otherwise       = []
    where
      addODate []   = []
      addODate xs   = [ODate xs]
      splitDate a b = case split (onSublist $ diff a b dp) dp of
                        [x,y,z] -> (x,y,z)
                        _       -> E.throw ErrorSplittingDate
      doRange   a b = let (x,y,z) = splitDate a b in
                      map (formatDatePart a) x ++
                      withDelim y
                        (map (formatDatePart a) (rmSuffix y))
                        (map (formatDatePart b) (rmPrefix y))
                        ++
                      map (formatDatePart b) z
      -- the point of rmPrefix is to remove the blank space that otherwise
      -- gets added after the delimiter in a range:  24- 26.
      rmPrefix (dp':rest) = dp'{ dpFormatting =
                                 (dpFormatting dp') { prefix = "" } } : rest
      rmPrefix []         = []
      rmSuffix (dp':rest)
         | null rest      = [dp'{ dpFormatting =
                                  (dpFormatting dp') { suffix = "" } }]
         | otherwise      = dp':rmSuffix rest
      rmSuffix []         = []

      diff (RefDate ya ma sa da _ _)
           (RefDate yb mb sb db _ _)
           = filter (\x -> dpName x `elem` ns)
              where ns =
                      case () of
                        _ | ya /= yb  -> ["year","month","day"]
                          | ma /= mb || sa /= sb ->
                            if da == mempty && db == mempty
                               then ["month"]
                               else ["month","day"]
                          | da /= db  -> ["day"]
                          | otherwise -> ["year","month","day"]

      term f t = let f' = if f `elem` ["verb", "short", "verb-short", "symbol"]
                          then read $ toRead f
                          else Long
                 in maybe [] termPlural $ findTerm t f' tm

      addZero n = if length n == 1 then '0' : n else n
      addZeros  = reverse . take 5 . flip (++) (repeat '0') . reverse
      formatDatePart (RefDate (Literal y) (Literal m)
        (Literal e) (Literal d) (Literal o) _) (DatePart n f _ fm)
          | "year"  <- n, y /= mempty = return $ OYear (formatYear  f    y) k fm
          | "month" <- n, m /= mempty = output fm      (formatMonth f fm m)
          | "day"   <- n, d /= mempty = output fm      (formatDay   f m  d)
          | "month" <- n, m == mempty
                        , e /= mempty = output fm $ term f ("season-0" ++ e)
          | "year"  <- n, o /= mempty = output fm o
          | otherwise                 = []

      withDelim _  [[]] [[]] = []
      withDelim xs o1 o2 = o1 ++
                           (case dpRangeDelim <$> last' xs of
                             ["-"] -> [[OPan [Str "\x2013"]]]
                             [s]   -> [[OPan [Str s]]]
                             _     -> []) ++ o2

      formatYear f y
          | "short" <- f = drop 2 y
          | isSorting em
          , iy < 0       = '-' : addZeros (tail y)
          | isSorting em = addZeros y
          | iy < 0       = show (abs iy) ++ term [] "bc"
          | length y < 4
          , iy /= 0      = y ++ term [] "ad"
          | iy == 0      = []
          | otherwise    = y
          where
            iy = readNum y
      formatMonth f fm m
          | "short"   <- f = getMonth $ period . termPlural
          | "long"    <- f = getMonth termPlural
          | "numeric" <- f = m
          | otherwise      = addZero m
          where
            period     = if stripPeriods fm then filter (/= '.') else id
            getMonth g = maybe m g $ findTerm ("month-" ++ addZero m) (read $ toRead f) tm
      formatDay f m d
          | "numeric-leading-zeros" <- f = addZero d
          | "ordinal"               <- f = ordinal tm ("month-" ++ addZero m) d
          | otherwise                    = d

ordinal :: [CslTerm] -> String -> String -> String
ordinal _ _ [] = []
ordinal ts v s
    | length s == 1 = let a = termPlural (getWith1 s) in
                      if  a == [] then setOrd (term []) else s ++ a
    | length s == 2 = let a = termPlural (getWith2 s)
                          b = getWith1 [last s] in
                      if  a /= []
                      then s ++ a
                      else if termPlural b == [] || (termMatch b /= [] && termMatch b /= "last-digit")
                           then setOrd (term []) else setOrd b
    | otherwise     = let a = getWith2  last2
                          b = getWith1 [last s] in
                      if termPlural a /= [] && termMatch a /= "whole-number"
                      then setOrd a
                      else if termPlural b == [] || (termMatch b /= [] && termMatch b /= "last-digit")
                           then setOrd (term []) else setOrd b
    where
      setOrd   = (++) s . termPlural
      getWith1 = term . (++) "-0"
      getWith2 = term . (++) "-"
      last2    = reverse . take 2 . reverse $ s
      term   t = getOrdinal v ("ordinal" ++ t) ts

longOrdinal :: [CslTerm] -> String -> String -> String
longOrdinal _ _ [] = []
longOrdinal ts v s
    | num > 10 ||
      num == 0  = ordinal ts v s
    | otherwise = case last s of
                    '1' -> term "01"
                    '2' -> term "02"
                    '3' -> term "03"
                    '4' -> term "04"
                    '5' -> term "05"
                    '6' -> term "06"
                    '7' -> term "07"
                    '8' -> term "08"
                    '9' -> term "09"
                    _   -> term "10"
    where
      num    = readNum s
      term t = termPlural $ getOrdinal v ("long-ordinal-" ++ t) ts

getOrdinal :: String -> String -> [CslTerm] -> CslTerm
getOrdinal v s ts
    = case findTerm' s Long gender ts of
        Just  x -> x
        Nothing -> case findTerm' s Long Neuter ts of
                     Just  x -> x
                     Nothing -> newTerm
    where
      gender = if v `elem` numericVars || "month" `isPrefixOf` v
               then maybe Neuter termGender $ findTerm v Long ts
               else Neuter

