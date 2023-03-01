{-# language DeriveAnyClass #-}
{-# language DeriveGeneric #-}
{-# language DeriveFoldable #-}
{-# language DeriveFunctor #-}
{-# language DeriveTraversable #-}
{-# language DerivingStrategies #-}
{-# language TupleSections #-}

-- edTODO document

module Chainweb.Utils.Rule where

import Control.DeepSeq

import Data.Aeson
import Data.Hashable
import qualified Data.List.NonEmpty as NE
import Data.Functor.Apply
import Data.Semigroup.Foldable
import Data.Semigroup.Traversable
import qualified Data.Vector as V

import GHC.Generics

data Rule h a = Above (h, a) (Rule h a) | End a
    deriving stock (Eq, Ord, Show, Foldable, Functor, Generic, Generic1, Traversable)
    deriving anyclass (Hashable, NFData)

instance Foldable1 (Rule h) where foldMap1 = foldMap1Default
instance Traversable1 (Rule h) where
    traverse1 f (Above (h, a) t) = Above <$> ((h,) <$> f a) <.> traverse1 f t
    traverse1 f (End a) = End <$> f a

instance (ToJSON h, ToJSON a) => ToJSON (Rule h a) where
    toJSON = toJSON . go
      where
        go (Above (h, a) t) = toJSON (toJSON h, toJSON a) : go t
        go (End a) = [toJSON a]

instance (FromJSON h, FromJSON a) => FromJSON (Rule h a) where
    parseJSON = withArray "Rule" $ go . V.toList
      where
        go [] = fail "empty list"
        go [a] = End <$> parseJSON a
        go (x:xs) = Above <$> parseJSON x <*> go xs

ruleHead :: Rule h a -> (Maybe h, a)
ruleHead (Above (h, a) _) = (Just h, a)
ruleHead (End a) = (Nothing, a)

ruleTakeWhile :: (h -> Bool) -> Rule h a -> Rule h a
ruleTakeWhile p (Above (h, a) t)
    | p h = Above (h, a) (ruleTakeWhile p t)
    | otherwise = ruleTakeWhile p t
ruleTakeWhile _ t = t

ruleDropWhile :: (h -> Bool) -> Rule h a -> Rule h a
ruleDropWhile p (Above (h, a) t)
    | p h = ruleDropWhile p t
    | otherwise = Above (h, a) t
ruleDropWhile _ t = t

data Measurement h a = Bottom a | Top (h, a) | Between (h, a) (h, a)

measureRule' :: (h -> Bool) -> Rule h a -> Measurement h a
measureRule' p ((topH, topA) `Above` topTail)
    | p topH = Top (topH, topA)
    | otherwise = go topH topA topTail
  where
    go lh la (Above (h, a) t)
        | p h = Between (lh, la) (h, a)
        | otherwise = go h a t
    go _ _ (End a) = Bottom a
measureRule' _ (End a) = Bottom a

measureRule :: Ord h => h -> Rule h a -> Measurement h a
measureRule h =
    measureRule' (\hc -> h >= hc)

ruleElemHeight :: Eq a => (a -> Bool) -> Rule h a -> Maybe (Maybe h)
ruleElemHeight p (Above (h, a) t)
    | p a = Just (Just h)
    | otherwise = ruleElemHeight p t
ruleElemHeight p (End a)
    | p a = Just Nothing
    | otherwise = Nothing

ruleElems :: h -> Rule h a -> NE.NonEmpty (h, a)
ruleElems h (End a) = (h, a) NE.:| []
ruleElems he (Above (h, a) t) = (h, a) `NE.cons` ruleElems he t

ruleValid :: Ord h => Rule h a -> Bool
ruleValid (Above (h, _) t@(Above (h', _) _)) = h >= h' && ruleValid t
ruleValid _ = True