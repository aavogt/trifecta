{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE TypeFamilies #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Text.Trifecta.Util.It
-- Copyright   :  (C) 2011-2013 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
-- harder, better, faster, stronger...
----------------------------------------------------------------------------
module Text.Trifecta.Util.It
  ( It(Pure, It)
  , needIt
  , wantIt
  , simplifyIt
  , runIt
  , fillIt
  , rewindIt
  , sliceIt
  ) where

import Control.Applicative
import Control.Comonad
import Control.Monad
import Data.Semigroup
import Data.Text as Strict
import Data.Text.Lazy as Lazy
import Text.Trifecta.Rope
import Text.Trifecta.Delta
import Text.Trifecta.Util.Combinators as Util

data It r a
  = Pure a
  | It a (r -> It r a)

instance Show a => Show (It r a) where
  showsPrec d (Pure a) = showParen (d > 10) $ showString "Pure " . showsPrec 11 a
  showsPrec d (It a _) = showParen (d > 10) $ showString "It " . showsPrec 11 a . showString " ..."

instance Functor (It r) where
  fmap f (Pure a) = Pure $ f a
  fmap f (It a k) = It (f a) $ fmap f . k

instance Applicative (It r) where
  pure = Pure
  Pure f  <*> Pure a  = Pure $ f a
  Pure f  <*> It a ka = It (f a) $ fmap f . ka
  It f kf <*> Pure a  = It (f a) $ fmap ($a) . kf
  It f kf <*> It a ka = It (f a) $ \r -> kf r <*> ka r

indexIt :: It r a -> r -> a
indexIt (Pure a) _ = a
indexIt (It _ k) r = extract (k r)

simplifyIt :: It r a -> r -> It r a
simplifyIt (It _ k) r = k r
simplifyIt pa _       = pa

instance Monad (It r) where
  return = Pure
  Pure a >>= f = f a
  It a k >>= f = It (extract (f a)) $ \r -> case k r of
    It a' k' -> It (indexIt (f a') r) $ k' >=> f
    Pure a' -> simplifyIt (f a') r

instance ComonadApply (It r) where (<@>) = (<*>)

-- | It is a cofree comonad
instance Comonad (It r) where
  duplicate p@Pure{} = Pure p
  duplicate p@(It _ k) = It p (duplicate . k)
  extend f p@Pure{} = Pure (f p)
  extend f p@(It _ k) = It (f p) (extend f . k)
  extract (Pure a) = a
  extract (It a _) = a

needIt :: a -> (r -> Maybe a) -> It r a
needIt z f = k where
  k = It z $ \r -> case f r of
    Just a -> Pure a
    Nothing -> k

wantIt :: a -> (r -> (# Bool, a #)) -> It r a
wantIt z f = It z k where
  k r = case f r of
    (# False, a #) -> It a k
    (# True,  a #) -> Pure a

-- scott decoding
runIt :: (a -> o) -> (a -> (r -> It r a) -> o) -> It r a -> o
runIt p _ (Pure a) = p a
runIt _ i (It a k) = i a k

-- * Rope specifics

-- | Given a position, go there, and grab the text forward from that point
fillIt :: r -> (Delta -> Strict.Text -> r) -> Delta -> It Rope r
fillIt kf ks n = wantIt kf $ \r ->
  (# units n < units (rewind (delta r))
  ,  grabLine n r kf ks #)


-- | Return the text of the line that contains a given position
rewindIt :: Delta -> It Rope (Maybe Strict.Text)
rewindIt n = wantIt Nothing $ \r ->
  (# units n < units (rewind (delta r))
  ,  grabLine (rewind n) r Nothing $ const Just #)

sliceIt :: Delta -> Delta -> It Rope Strict.Text
sliceIt !i !j = wantIt mempty $ \r ->
  (# bj < units (rewind (delta r))
  ,  grabRest i r mempty $ const $ Util.fromLazy . Lazy.take (fromIntegral (bj - bi)) #)
  where
    bi = units i
    bj = units j