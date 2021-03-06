{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- | Implementation of the @dhall to-directory-tree@ subcommand
module Dhall.DirectoryTree
    ( -- * Filesystem
      toDirectoryTree
    , FilesystemError(..)
    ) where

import Control.Applicative (empty)
import Control.Exception (Exception)
import Data.Monoid ((<>))
import Data.Void (Void)
import Dhall.Syntax (Chunks(..), Expr(..))
import System.FilePath ((</>))

import qualified Control.Exception                       as Exception
import qualified Data.Foldable                           as Foldable
import qualified Data.Text                               as Text
import qualified Data.Text.IO                            as Text.IO
import qualified Data.Text.Prettyprint.Doc.Render.String as Pretty
import qualified Dhall.Map                               as Map
import qualified Dhall.Pretty
import qualified Dhall.Util                              as Util
import qualified System.Directory                        as Directory
import qualified System.FilePath                         as FilePath

{-| Attempt to transform a Dhall record into a directory tree where:

    * Records are translated into directories

    * @Map@s are also translated into directories

    * @Text@ values or fields are translated into files

    * @Optional@ values are omitted if @None@

    For example, the following Dhall record:

    > { dir = { `hello.txt` = "Hello\n" }
    > , `goodbye.txt`= Some "Goodbye\n"
    > , `missing.txt` = None Text
    > }

    ... should translate to this directory tree:

    > $ tree result
    > result
    > ├── dir
    > │   └── hello.txt
    > └── goodbye.txt
    >
    > $ cat result/dir/hello.txt
    > Hello
    >
    > $ cat result/goodbye.txt
    > Goodbye

    Use this in conjunction with the Prelude's support for rendering JSON/YAML
    in "pure Dhall" so that you can generate files containing JSON.  For
    example:

    > let JSON =
    >       https://prelude.dhall-lang.org/v12.0.0/JSON/package.dhall sha256:843783d29e60b558c2de431ce1206ce34bdfde375fcf06de8ec5bf77092fdef7
    >
    > in  { `example.json` =
    >         JSON.render (JSON.array [ JSON.number 1.0, JSON.bool True ])
    >     , `example.yaml` =
    >         JSON.renderYAML
    >           (JSON.object (toMap { foo = JSON.string "Hello", bar = JSON.null }))
    >     }

    ... which would generate:

    > $ cat result/example.json
    > [ 1.0, true ]
    >
    > $ cat result/example.yaml
    > ! "bar": null
    > ! "foo": "Hello"

    This utility does not take care of type-checking and normalizing the
    provided expression.  This will raise a `FilesystemError` exception upon
    encountering an expression that cannot be converted as-is.
-}
toDirectoryTree :: FilePath -> Expr Void Void -> IO ()
toDirectoryTree path expression = case expression of
    RecordLit keyValues -> do
        Map.unorderedTraverseWithKey_ process keyValues

    ListLit (Just (Record [ ("mapKey", Text), ("mapValue", _) ])) [] -> do
        return ()

    ListLit _ records
        | not (null records)
        , Just keyValues <- extract (Foldable.toList records) -> do
            Foldable.traverse_ (uncurry process) keyValues

    TextLit (Chunks [] text) -> do
        Text.IO.writeFile path text

    Some value -> do
        toDirectoryTree path value

    App None _ -> do
        return ()

    _ -> do
        die
  where
    extract [] = do
        return []

    extract (RecordLit [("mapKey", TextLit (Chunks [] key)), ("mapValue", value)]:records) = do
        fmap ((key, value) :) (extract records)

    extract _ = do
        empty

    process key value = do
        if Text.isInfixOf (Text.pack [ FilePath.pathSeparator ]) key
            then die
            else return ()

        Directory.createDirectoryIfMissing False path

        toDirectoryTree (path </> Text.unpack key) value

    die = Exception.throwIO FilesystemError{..}
      where
        unexpectedExpression = expression

{- | This error indicates that you supplied an invalid Dhall expression to the
     `directoryTree` function.  The Dhall expression could not be translated to
     a directory tree.
-}
newtype FilesystemError =
    FilesystemError { unexpectedExpression :: Expr Void Void }

instance Show FilesystemError where
    show FilesystemError{..} =
        Pretty.renderString (Dhall.Pretty.layout message)
      where
        message =
          Util._ERROR <> ": Not a valid directory tree expression\n\
          \                                                                                \n\
          \Explanation: Only a subset of Dhall expressions can be converted to a directory \n\
          \tree.  Specifically, record literals or maps can be converted to directories,   \n\
          \❰Text❱ literals can be converted to files, and ❰Optional❱ values are included if\n\
          \❰Some❱ and omitted if ❰None❱.  No other type of value can be translated to a    \n\
          \directory tree.                                                                 \n\
          \                                                                                \n\
          \For example, this is a valid expression that can be translated to a directory   \n\
          \tree:                                                                           \n\
          \                                                                                \n\
          \                                                                                \n\
          \    ┌──────────────────────────────────┐                                        \n\
          \    │ { `example.json` = \"[1, true]\" } │                                      \n\
          \    └──────────────────────────────────┘                                        \n\
          \                                                                                \n\
          \                                                                                \n\
          \In contrast, the following expression is not allowed due to containing a        \n\
          \❰Natural❱ field, which cannot be translated in this way:                        \n\
          \                                                                                \n\
          \                                                                                \n\
          \    ┌───────────────────────┐                                                   \n\
          \    │ { `example.txt` = 1 } │                                                   \n\
          \    └───────────────────────┘                                                   \n\
          \                                                                                \n\
          \                                                                                \n\
          \Note that key names cannot contain path separators:                             \n\
          \                                                                                \n\
          \                                                                                \n\
          \    ┌───────────────────────────────────┐                                       \n\
          \    │ { `directory/example.txt` = \"ABC\" │ Invalid: Key contains a forward slash \n\
          \    └───────────────────────────────────┘                                       \n\
          \                                                                                \n\
          \                                                                                \n\
          \Instead, you need to refactor the expression to use nested records instead:     \n\
          \                                                                                \n\
          \                                                                                \n\
          \    ┌───────────────────────────────────────────┐                               \n\
          \    │ { directory = { `example.txt` = \"ABC\" } } │                               \n\
          \    └───────────────────────────────────────────┘                               \n\
          \                                                                                \n\
          \                                                                                \n\
          \You tried to translate the following expression to a directory tree:            \n\
          \                                                                                \n\
          \" <> Util.insert unexpectedExpression <> "\n\
          \                                                                                \n\
          \... which is not an expression that can be translated to a directory tree.      \n"

instance Exception FilesystemError
