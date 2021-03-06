{-# LANGUAGE CPP, GADTs, DefaultSignatures, FlexibleContexts, DeriveFunctor,
    ScopedTypeVariables #-}

-- |
-- Module:      Data.Aeson.Types.Class
-- Copyright:   (c) 2011-2016 Bryan O'Sullivan
--              (c) 2011 MailRank, Inc.
-- License:     BSD3
-- Maintainer:  Bryan O'Sullivan <bos@serpentine.com>
-- Stability:   experimental
-- Portability: portable
--
-- Types for working with JSON data.

module Data.Aeson.Types.Class
    (
    -- * Core JSON classes
      FromJSON(..)
    , ToJSON(..)
    -- * Generic JSON classes
    , GFromJSON(..)
    , GToJSON(..)
    , GToEncoding(..)
    , genericToJSON
    , genericToEncoding
    , genericParseJSON
    -- * Classes and types for map keys
    , ToJSONKeyFunction(..)
    , FromJSONKeyFunction(..)
    , fromJSONKeyCoerce
    , coerceFromJSONKeyFunction
    -- * Object key-value pairs
    , KeyValue(..)
    -- * Functions needed for documentation
    , typeMismatch
    ) where

import Data.Aeson.Types.Internal
import Data.Text (Text)
import GHC.Generics (Generic, Rep, from, to)
import Data.Monoid ((<>))
import Data.Aeson.Encode.Builder (emptyArray_)
import qualified Data.ByteString.Builder as B
import qualified Data.Aeson.Encode.Builder as E
import qualified Data.Vector as V

-- Coercible derivations aren't as powerful on GHC 7.8, though supported.
#define HAS_COERCIBLE (__GLASGOW_HASKELL__ >= 709)

#if HAS_COERCIBLE
import Data.Coerce (Coercible, coerce)
coerce' :: Coercible a b => a -> b
coerce' = coerce
#else
import Unsafe.Coerce (unsafeCoerce)
coerce' :: a -> b
coerce' = unsafeCoerce
#endif

-- | Class of generic representation types ('Rep') that can be converted to
-- JSON.
class GToJSON f where
    -- | This method (applied to 'defaultOptions') is used as the
    -- default generic implementation of 'toJSON'.
    gToJSON :: Options -> f a -> Value

-- | Class of generic representation types ('Rep') that can be converted to
-- a JSON 'Encoding'.
class GToEncoding f where
    -- | This method (applied to 'defaultOptions') can be used as the
    -- default generic implementation of 'toEncoding'.
    gToEncoding :: Options -> f a -> Encoding

-- | Class of generic representation types ('Rep') that can be converted from JSON.
class GFromJSON f where
    -- | This method (applied to 'defaultOptions') is used as the
    -- default generic implementation of 'parseJSON'.
    gParseJSON :: Options -> Value -> Parser (f a)

-- | A configurable generic JSON creator. This function applied to
-- 'defaultOptions' is used as the default for 'toJSON' when the type
-- is an instance of 'Generic'.
genericToJSON :: (Generic a, GToJSON (Rep a)) => Options -> a -> Value
genericToJSON opts = gToJSON opts . from

-- | A configurable generic JSON encoder. This function applied to
-- 'defaultOptions' is used as the default for 'toEncoding' when the type
-- is an instance of 'Generic'.
genericToEncoding :: (Generic a, GToEncoding (Rep a)) => Options -> a -> Encoding
genericToEncoding opts = gToEncoding opts . from

-- | A configurable generic JSON decoder. This function applied to
-- 'defaultOptions' is used as the default for 'parseJSON' when the
-- type is an instance of 'Generic'.
genericParseJSON :: (Generic a, GFromJSON (Rep a)) => Options -> Value -> Parser a
genericParseJSON opts = fmap to . gParseJSON opts

-- | A type that can be converted to JSON.
--
-- An example type and instance:
--
-- @
-- \-- Allow ourselves to write 'Text' literals.
-- {-\# LANGUAGE OverloadedStrings #-}
--
-- data Coord = Coord { x :: Double, y :: Double }
--
-- instance ToJSON Coord where
--   toJSON (Coord x y) = 'object' [\"x\" '.=' x, \"y\" '.=' y]
--
--   toEncoding (Coord x y) = 'pairs' (\"x\" '.=' x '<>' \"y\" '.=' y)
-- @
--
-- Instead of manually writing your 'ToJSON' instance, there are two options
-- to do it automatically:
--
-- * "Data.Aeson.TH" provides Template Haskell functions which will derive an
-- instance at compile time. The generated instance is optimized for your type
-- so will probably be more efficient than the following two options:
--
-- * The compiler can provide a default generic implementation for
-- 'toJSON'.
--
-- To use the second, simply add a @deriving 'Generic'@ clause to your
-- datatype and declare a 'ToJSON' instance for your datatype without giving
-- definitions for 'toJSON' or 'toEncoding'.
--
-- For example, the previous example can be simplified to a more
-- minimal instance:
--
-- @
-- {-\# LANGUAGE DeriveGeneric \#-}
--
-- import "GHC.Generics"
--
-- data Coord = Coord { x :: Double, y :: Double } deriving 'Generic'
--
-- instance ToJSON Coord where
--     toEncoding = 'genericToEncoding' 'defaultOptions'
-- @
--
-- Why do we provide an implementation for 'toEncoding' here?  The
-- 'toEncoding' function is a relatively new addition to this class.
-- To allow users of older versions of this library to upgrade without
-- having to edit all of their instances or encounter surprising
-- incompatibilities, the default implementation of 'toEncoding' uses
-- 'toJSON'.  This produces correct results, but since it performs an
-- intermediate conversion to a 'Value', it will be less efficient
-- than directly emitting an 'Encoding'.  Our one-liner definition of
-- 'toEncoding' above bypasses the intermediate 'Value'.
--
-- If @DefaultSignatures@ doesn't give exactly the results you want,
-- you can customize the generic encoding with only a tiny amount of
-- effort, using 'genericToJSON' and 'genericToEncoding' with your
-- preferred 'Options':
--
-- @
-- instance ToJSON Coord where
--     toJSON     = 'genericToJSON' 'defaultOptions'
--     toEncoding = 'genericToEncoding' 'defaultOptions'
-- @
class ToJSON a where
    -- | Convert a Haskell value to a JSON-friendly intermediate type.
    toJSON     :: a -> Value

    default toJSON :: (Generic a, GToJSON (Rep a)) => a -> Value
    toJSON = genericToJSON defaultOptions

    -- | Encode a Haskell value as JSON.
    --
    -- The default implementation of this method creates an
    -- intermediate 'Value' using 'toJSON'.  This provides
    -- source-level compatibility for people upgrading from older
    -- versions of this library, but obviously offers no performance
    -- advantage.
    --
    -- To benefit from direct encoding, you /must/ provide an
    -- implementation for this method.  The easiest way to do so is by
    -- having your types implement 'Generic' using the @DeriveGeneric@
    -- extension, and then have GHC generate a method body as follows.
    --
    -- @
    -- instance ToJSON Coord where
    --     toEncoding = 'genericToEncoding' 'defaultOptions'
    -- @

    toEncoding :: a -> Encoding
    toEncoding = Encoding . E.encodeToBuilder . toJSON
    {-# INLINE toEncoding #-}

-- | A type that can be converted from JSON, with the possibility of
-- failure.
--
-- In many cases, you can get the compiler to generate parsing code
-- for you (see below).  To begin, let's cover writing an instance by
-- hand.
--
-- There are various reasons a conversion could fail.  For example, an
-- 'Object' could be missing a required key, an 'Array' could be of
-- the wrong size, or a value could be of an incompatible type.
--
-- The basic ways to signal a failed conversion are as follows:
--
-- * 'empty' and 'mzero' work, but are terse and uninformative
--
-- * 'fail' yields a custom error message
--
-- * 'typeMismatch' produces an informative message for cases when the
-- value encountered is not of the expected type
--
-- An example type and instance:
--
-- @
-- \-- Allow ourselves to write 'Text' literals.
-- {-\# LANGUAGE OverloadedStrings #-}
--
-- data Coord = Coord { x :: Double, y :: Double }
--
-- instance FromJSON Coord where
--   parseJSON ('Object' v) = Coord    '<$>'
--                          v '.:' \"x\" '<*>'
--                          v '.:' \"y\"
--
--   \-- We do not expect a non-'Object' value here.
--   \-- We could use 'mzero' to fail, but 'typeMismatch'
--   \-- gives a much more informative error message.
--   parseJSON invalid    = 'typeMismatch' \"Coord\" invalid
-- @
--
-- Instead of manually writing your 'FromJSON' instance, there are two options
-- to do it automatically:
--
-- * "Data.Aeson.TH" provides Template Haskell functions which will derive an
-- instance at compile time. The generated instance is optimized for your type
-- so will probably be more efficient than the following two options:
--
-- * The compiler can provide a default generic implementation for
-- 'parseJSON'.
--
-- To use the second, simply add a @deriving 'Generic'@ clause to your
-- datatype and declare a 'FromJSON' instance for your datatype without giving
-- a definition for 'parseJSON'.
--
-- For example, the previous example can be simplified to just:
--
-- @
-- {-\# LANGUAGE DeriveGeneric \#-}
--
-- import "GHC.Generics"
--
-- data Coord = Coord { x :: Double, y :: Double } deriving 'Generic'
--
-- instance FromJSON Coord
-- @
--
-- If @DefaultSignatures@ doesn't give exactly the results you want,
-- you can customize the generic decoding with only a tiny amount of
-- effort, using 'genericParseJSON' with your preferred 'Options':
--
-- @
-- instance FromJSON Coord where
--     parseJSON = 'genericParseJSON' 'defaultOptions'
-- @

class FromJSON a where
    parseJSON :: Value -> Parser a

    default parseJSON :: (Generic a, GFromJSON (Rep a)) => Value -> Parser a
    parseJSON = genericParseJSON defaultOptions

-- | A key-value pair for encoding a JSON object.
class KeyValue kv where
    (.=) :: ToJSON v => Text -> v -> kv
    infixr 8 .=

data ToJSONKeyFunction a
    = ToJSONKeyText (a -> Text, a -> Encoding)
    | ToJSONKeyValue (a -> Value, a -> Encoding)

-- | With GHC 7.8 + we carry around 'Coercible Text a' dictionary,
-- to have even some amount of safety net.
-- Unfortunately we cannot enforce that 'Hashable' instance agree on the type level
--
-- ATM this type is intentionally not exported. FromJSONKeyFunction can be inspected,
-- but cannot be constructed.
data CoerceText a where
#if HAS_COERCIBLE
    CoerceText :: Coercible Text a => CoerceText a
#else
    CoerceText :: CoerceText a
#endif

data FromJSONKeyFunction a
    = FromJSONKeyCoerce (CoerceText a)
    | FromJSONKeyText (Text -> a)
    | FromJSONKeyTextParser (Text -> Parser a)
    | FromJSONKeyValue (Value -> Parser a)

instance Functor FromJSONKeyFunction where
    fmap h (FromJSONKeyCoerce CoerceText) = FromJSONKeyText (h . coerce')
    fmap h (FromJSONKeyText f)            = FromJSONKeyText (h . f)
    fmap h (FromJSONKeyTextParser f)      = FromJSONKeyTextParser (fmap h . f)
    fmap h (FromJSONKeyValue f)           = FromJSONKeyValue (fmap h . f)

-- | Construct 'FromJSONKeyFunction' for types coercible from 'Text'. This
-- conversion is still unsafe, as 'Hashable' and 'Eq' instances of @a@ should be
-- compatible with 'Text' i.e. hash values be equal for wrapped values as well.
fromJSONKeyCoerce ::
#if HAS_COERCIBLE
    Coercible Text a =>
#endif
    FromJSONKeyFunction a
fromJSONKeyCoerce = FromJSONKeyCoerce CoerceText

coerceFromJSONKeyFunction ::
#if HAS_COERCIBLE
    Coercible a b =>
#endif
    FromJSONKeyFunction a -> FromJSONKeyFunction b
coerceFromJSONKeyFunction (FromJSONKeyCoerce CoerceText) = FromJSONKeyCoerce CoerceText
coerceFromJSONKeyFunction (FromJSONKeyText f)            = FromJSONKeyText (coerce' . f)
coerceFromJSONKeyFunction (FromJSONKeyTextParser f)      = FromJSONKeyTextParser (fmap coerce' . f)
coerceFromJSONKeyFunction (FromJSONKeyValue f)           = FromJSONKeyValue (fmap coerce' . f)

{-# RULES
  "FromJSONKeyCoerce: fmap id"     forall (x :: FromJSONKeyFunction a).
                                   fmap id x = x
  #-}
#if HAS_COERCIBLE
{-# RULES
  "FromJSONKeyCoerce: fmap coerce" forall x .
                                   fmap coerce x = coerceFromJSONKeyFunction x
  #-}
#endif

-- | Fail parsing due to a type mismatch, with a descriptive message.
--
-- Example usage:
--
-- @
-- instance FromJSON Coord where
--   parseJSON ('Object' v) = {- type matches, life is good -}
--   parseJSON wat        = 'typeMismatch' \"Coord\" wat
-- @
typeMismatch :: String -- ^ The name of the type you are trying to parse.
             -> Value  -- ^ The actual value encountered.
             -> Parser a
typeMismatch expected actual =
    fail $ "expected " ++ expected ++ ", encountered " ++ name
  where
    name = case actual of
             Object _ -> "Object"
             Array _  -> "Array"
             String _ -> "String"
             Number _ -> "Number"
             Bool _   -> "Boolean"
             Null     -> "Null"
