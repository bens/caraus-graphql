{- This Source Code Form is subject to the terms of the Mozilla Public License,
   v. 2.0. If a copy of the MPL was not distributed with this file, You can
   obtain one at https://mozilla.org/MPL/2.0/. -}

{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Test helpers.
module Test.Hspec.GraphQL
    ( shouldResolve
    , shouldResolveTo
    ) where

import qualified Data.Aeson as Aeson
import qualified Data.HashMap.Strict as HashMap
import Data.Text (Text)
import Language.GraphQL.Error
import Test.Hspec.Expectations (Expectation, expectationFailure, shouldBe, shouldNotSatisfy)

-- | Asserts that a query resolves to some value.
shouldResolveTo
    :: Either (ResponseEventStream IO Aeson.Value) Aeson.Object
    -> Aeson.Object
    -> Expectation
shouldResolveTo (Right actual) expected = actual `shouldBe` expected
shouldResolveTo _ _ = expectationFailure
    "the query is expected to resolve to a value, but it resolved to an event stream"

-- | Asserts that the response doesn't contain any errors.
shouldResolve
    :: (Text -> IO (Either (ResponseEventStream IO Aeson.Value) Aeson.Object))
    -> Text
    -> Expectation
shouldResolve executor query = do
    actual <- executor query
    case actual of
        Right response ->
            response `shouldNotSatisfy` HashMap.member "errors"
        _ -> expectationFailure
            "the query is expected to resolve to a value, but it resolved to an event stream"
