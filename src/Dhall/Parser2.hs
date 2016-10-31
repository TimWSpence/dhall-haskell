{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}

module Dhall.Parser2 where
{-
module Dhall.Parser2 (
    -- * Parser
      exprFromText

    -- * Types
    , Src(..)
    , ParseError(..)
    ) where
-}

import Control.Applicative (Alternative(..), optional)
import Control.Exception (Exception)
import Control.Monad (MonadPlus)
import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Monoid ((<>))
import Data.Text.Lazy (Text)
import Data.Typeable (Typeable)
import Data.Vector (Vector)
import Dhall.Core (Const(..), Expr(..), Path(..), Var(..))
import Filesystem.Path (FilePath)
import Prelude hiding (FilePath, const, pi)
import Text.PrettyPrint.ANSI.Leijen (Doc)
import Text.Parser.Combinators (choice, try)
import Text.Parser.Expression (Assoc(..), Operator(..))
import Text.Parser.Token (IdentifierStyle(..), TokenParsing(..))
import Text.Parser.Token.Highlight (Highlight(..))
import Text.Parser.Token.Style (CommentStyle(..))
import Text.Trifecta (CharParsing, DeltaParsing, Parsing, Result(..))
import Text.Trifecta.Delta (Delta)

import qualified Data.Char
import qualified Data.HashSet
import qualified Data.List
import qualified Data.Map
import qualified Data.Text.Lazy
import qualified Data.Vector
import qualified Filesystem.Path.CurrentOS
import qualified Text.Parser.Char
import qualified Text.Parser.Combinators
import qualified Text.Parser.Expression
import qualified Text.Parser.Token
import qualified Text.Parser.Token.Style
import qualified Text.Trifecta

-- TODO: Go through alternatives and see which ones require `try`

data Src = Src Delta Delta ByteString deriving (Show)

newtype Parser a = Parser { unParser :: Text.Trifecta.Parser a }
    deriving
    (   Functor
    ,   Applicative
    ,   Monad
    ,   Alternative
    ,   MonadPlus
    ,   Parsing
    ,   CharParsing
    ,   DeltaParsing
    )

instance TokenParsing Parser where
    someSpace =
        Text.Parser.Token.Style.buildSomeSpaceParser 
            (Parser someSpace)
            Text.Parser.Token.Style.haskellCommentStyle

    nesting (Parser m) = Parser (nesting m)

    semi = Parser semi

    highlight h (Parser m) = Parser (highlight h m)

    token parser = do
        r <- parser
        Text.Parser.Token.whiteSpace
        return r

identifierStyle :: IdentifierStyle Parser
identifierStyle = IdentifierStyle
    { _styleName     = "dhall"
    -- TODO: Restrict start and letter to ASCII letters
    , _styleStart    = Text.Parser.Char.letter   <|> Text.Parser.Char.char '_'
    , _styleLetter   = Text.Parser.Char.alphaNum <|> Text.Parser.Char.oneOf "_/"
    , _styleReserved = Data.HashSet.fromList
        -- TODO: Ensure that this list is complete
        [ "let"
        , "in"
        , "Type"
        , "Kind"
        , "forall"
        , "∀"
        , "Bool"
        , "True"
        , "False"
        , "apply"
        , "if"
        , "then"
        , "else"
        , "Natural"
        , "Natural/fold"
        , "Natural/build"
        , "Natural/isZero"
        , "Natural/even"
        , "Natural/odd"
        , "Integer"
        , "Double"
        , "Text"
        , "List"
        , "List/build"
        , "List/fold"
        , "List/length"
        , "List/head"
        , "List/last"
        , "List/indexed"
        , "List/reverse"
        , "Maybe"
        , "Maybe/fold"
        ]
    , _styleHighlight         = Identifier
    , _styleReservedHighlight = ReservedIdentifier
    }

noted :: Parser (Expr Src a) -> Parser (Expr Src a)
noted parser = do
    before        <- Text.Trifecta.position
    (expr, bytes) <- Text.Trifecta.slicedWith (,) parser
    after         <- Text.Trifecta.position
    return (Note (Src before after bytes) expr)

reserve :: String -> Parser ()
reserve string = do
    _ <- Text.Parser.Token.reserve identifierStyle string
    return ()

symbol :: String -> Parser ()
symbol string = do
    _ <- Text.Parser.Token.symbol string
    return ()

lambda :: Parser ()
lambda = symbol "\\" <|> symbol "λ"

pi :: Parser ()
pi = reserve "forall" <|> reserve "∀"

arrow :: Parser ()
arrow = symbol "->" <|> symbol "→"

merge :: Parser ()
merge = symbol "/\\" <|> symbol "∧"

label :: Parser Text
label = Text.Parser.Token.ident identifierStyle

exprA :: Parser (Expr Src Path)
exprA = noted (try exprA0)
    <|>            exprA1
  where
    exprA0 = do
        a <- exprB
        symbol ":"
        b <- exprA
        return (Annot a b)

    exprA1 = exprB

exprB :: Parser (Expr Src Path)
exprB = choice
    [   noted      exprB0
    ,   noted      exprB1
    ,   noted      exprB3
    ,   noted      exprB5
    ,   noted      exprB6
    ,   noted      exprB7
    ,   noted (try exprB2)
    ,              exprB8
    ]
  where
    exprB0 = do
        lambda
        symbol "("
        a <- label
        symbol ":"
        b <- exprA
        symbol ")"
        arrow
        c <- exprB
        return (Lam a b c)

    exprB1 = do
        reserve "if"
        a <- exprA
        reserve "then"
        b <- exprB
        reserve "else"
        c <- exprC
        return (BoolIf a b c)

    exprB2 = do
        a <- exprC
        arrow
        b <- exprB
        return (Pi "_" a b)

    exprB3 = do
        pi
        symbol "("
        a <- label
        symbol ":"
        b <- exprA
        symbol ")"
        arrow
        c <- exprB
        return (Pi a b c)

    exprB5 = do
        reserve "let"
        a <- label
        b <- optional (do
            symbol ":"
            exprA )
        symbol "="
        c <- exprA
        reserve "in"
        d <- exprB
        return (Let a b c d)

    exprB6 = do
        symbol "["
        a <- elems
        symbol "]"
        symbol ":"
        b <- listLike
        c <- exprE
        return (b c (Data.Vector.fromList a))

    exprB7 = do
        reserve "apply"
        a <- exprE
        b <- exprE
        symbol ":"
        c <- exprD
        return (Apply a b c)

    exprB8 = exprC

listLike :: Parser (Expr Src Path -> Vector (Expr Src Path) -> Expr Src Path)
listLike =
    (   listLike0
    <|> listLike1
    )
  where
    listLike0 = do
        reserve "List"
        return ListLit

    listLike1 = do
        reserve "Maybe"
        return MaybeLit

-- TODO: Add `noted` in the right places here
exprC :: Parser (Expr Src Path)
exprC = expressionParser
  where
    expressionParser = Text.Parser.Expression.buildExpressionParser
        [ [ operator BoolAnd      (symbol "&&")
          , operator NaturalTimes (symbol "*" )
          , operator Merge         merge
          ]
        , [ operator BoolOr       (symbol "||")
          , operator NaturalPlus  (symbol "+" )
          , operator TextAppend   (symbol "++")
          ]
        , [ operator BoolEQ       (symbol "==")
          , operator BoolNE       (symbol "/=")
          ]
        ]
        exprD

    operator op parser = Infix (do parser; return op) AssocRight

-- TODO: Add `noted` here
exprD :: Parser (Expr Src Path)
exprD = do
    exprs <- some exprE
    return (Data.List.foldl1 App exprs)

exprE :: Parser (Expr Src Path)
exprE = do
    a <- exprF
    b <- many (do
        symbol "."
        label )
    return (Data.List.foldl Field a b)

exprF :: Parser (Expr Src Path)
exprF = choice
    [   noted      exprF01
    ,   noted      exprF03
    ,   noted      exprF04
    ,   noted      exprF05
    ,   noted      exprF06
    ,   noted      exprF07
    ,   noted      exprF12
    ,   noted      exprF13
    ,   noted      exprF14
    ,   noted      exprF15
    ,   noted      exprF16
    ,   noted      exprF17
    ,   noted      exprF18
    ,   noted      exprF20
    ,   noted      exprF19
    ,   noted      exprF21
    ,   noted      exprF22
    ,   noted (try exprF25)
    ,   noted      exprF23
    ,   noted      exprF24
    ,   noted      exprF26
    ,   noted (try exprF27)
    ,   noted      exprF28
    ,   noted (try exprF29)
    ,   noted      exprF30
    ,   noted      exprF31
    ,   noted      exprF02
    ,   noted      exprF08
    ,   noted      exprF09
    ,   noted      exprF10
    ,   noted      exprF11
    ,   noted      exprF00
    ,              exprF33
    ]
  where
    exprF00 = do
        a <- var
        return (Var a)

    exprF01 = do
        a <- const
        return (Const a)

    exprF02 = do
        reserve "Natural"
        return Natural

    exprF03 = do
        reserve "Natural/fold"
        return NaturalFold

    exprF04 = do
        reserve "Natural/build"
        return NaturalBuild

    exprF05 = do
        reserve "Natural/isZero"
        return NaturalIsZero

    exprF06 = do
        reserve "Natural/even"
        return NaturalEven

    exprF07 = do
        reserve "Natural/odd"
        return NaturalOdd

    exprF08 = do
        reserve "Integer"
        return Integer

    exprF09 = do
        reserve "Double"
        return Double

    exprF10 = do
        reserve "Text"
        return Text

    exprF11 = do
        reserve "List"
        return List

    exprF12 = do
        reserve "List/build"
        return ListBuild

    exprF13 = do
        reserve "List/fold"
        return ListFold

    exprF14 = do
        reserve "List/length"
        return ListLength

    exprF15 = do
        reserve "List/head"
        return ListHead

    exprF16 = do
        reserve "List/last"
        return ListLast

    exprF17 = do
        reserve "List/indexed"
        return ListIndexed

    exprF18 = do
        reserve "List/reverse"
        return ListReverse

    exprF19 = do
        reserve "Maybe"
        return Maybe

    exprF20 = do
        reserve "Maybe/fold"
        return MaybeFold

    exprF21 = do
        reserve "True"
        return (BoolLit True)

    exprF22 = do
        reserve "False"
        return (BoolLit False)

    exprF23 = do
        a <- Text.Parser.Token.natural
        return (IntegerLit a)

    exprF24 = do
        Text.Parser.Char.char '+'
        a <- Text.Parser.Token.natural
        return (NaturalLit (fromIntegral a))

    exprF25 = do
        a <- Text.Parser.Token.double
        return (DoubleLit a)

    exprF26 = do
        a <- Text.Parser.Token.stringLiteral
        return (TextLit a)

    exprF27 = record

    exprF28 = recordLit

    exprF29 = union

    exprF30 = unionLit

    exprF31 = do
        a <- import_
        return (Embed a)

    exprF33 = do
        symbol "("
        a <- exprA
        symbol ")"
        return a

const :: Parser Const
const = const0
    <|> const1
  where
    const0 = do
        reserve "Type"
        return Type

    const1 = do
        reserve "Kind"
        return Kind

var :: Parser Var
var = do
    a <- label
    m <- optional (do
        symbol "@"
        Text.Parser.Token.natural )
    let b = case m of
            Just b  -> b
            Nothing -> 0
    return (V a b)

elems :: Parser [Expr Src Path]
elems = Text.Parser.Combinators.sepBy exprA (symbol ",")

recordLit :: Parser (Expr Src Path)
recordLit =
        recordLit0
    <|> recordLit1
  where
    recordLit0 = do
        symbol "{=}"
        return (RecordLit (Data.Map.fromList []))

    recordLit1 = do
        symbol "{"
        a <- fieldValues
        symbol "}"
        return (RecordLit (Data.Map.fromList a))

fieldValues :: Parser [(Text, Expr Src Path)]
fieldValues =
    Text.Parser.Combinators.sepBy1 fieldValue (symbol ",")

fieldValue :: Parser (Text, Expr Src Path)
fieldValue = do
    a <- label
    symbol "="
    b <- exprA
    return (a, b)

record :: Parser (Expr Src Path)
record = do
    symbol "{"
    a <- fieldTypes
    symbol "}"
    return (Record (Data.Map.fromList a))

fieldTypes :: Parser [(Text, Expr Src Path)]
fieldTypes =
    Text.Parser.Combinators.sepBy fieldType (symbol ",")

fieldType :: Parser (Text, Expr Src Path)
fieldType = do
    a <- label
    symbol ":"
    b <- exprA
    return (a, b)

union :: Parser (Expr Src Path)
union = do
    symbol "<"
    a <- alternativeTypes
    symbol ">"
    return (Union (Data.Map.fromList a))

alternativeTypes :: Parser [(Text, Expr Src Path)]
alternativeTypes =
    Text.Parser.Combinators.sepBy alternativeType (symbol "|")

alternativeType :: Parser (Text, Expr Src Path)
alternativeType = do
    a <- label
    symbol ":"
    b <- exprA
    return (a, b)

unionLit :: Parser (Expr Src Path)
unionLit =
        try unionLit0
    <|>     unionLit1
  where
    unionLit0 = do
        symbol "<"
        a <- label
        symbol "="
        b <- exprA
        symbol ">"
        return (UnionLit a b Data.Map.empty)

    unionLit1 = do
        symbol "<"
        a <- label
        symbol "="
        b <- exprA
        symbol "|"
        c <- alternativeTypes
        symbol ">"
        return (UnionLit a b (Data.Map.fromList c))

import_ :: Parser Path
import_ =
        import0
    <|> import1
  where
    import0 = do
        a <- file
        return (File a)

    import1 = do
        a <- url
        return (URL a)

file :: Parser FilePath
file =  token file0
    <|> token file1
    <|> token file2
  where
    file0 = do
        a <- Text.Parser.Char.string "/"
        b <- many (Text.Parser.Char.satisfy (not . Data.Char.isSpace))
        return (Filesystem.Path.CurrentOS.decodeString (a <> b))

    file1 = do
        a <- Text.Parser.Char.string "./"
        b <- many (Text.Parser.Char.satisfy (not . Data.Char.isSpace))
        return (Filesystem.Path.CurrentOS.decodeString (a <> b))

    file2 = do
        a <- Text.Parser.Char.string "../"
        b <- many (Text.Parser.Char.satisfy (not . Data.Char.isSpace))
        return (Filesystem.Path.CurrentOS.decodeString (a <> b))

url :: Parser Text
url =   url0
    <|> url1
  where
    url0 = do
        a <- Text.Parser.Char.string "https://"
        b <- many (Text.Parser.Char.satisfy (not . Data.Char.isSpace))
        return (Data.Text.Lazy.pack (a <> b))

    url1 = do
        a <- Text.Parser.Char.string "http://"
        b <- many (Text.Parser.Char.satisfy (not . Data.Char.isSpace))
        return (Data.Text.Lazy.pack (a <> b))

-- | A parsing error
newtype ParseError = ParseError Doc deriving (Typeable)

instance Show ParseError where
    show (ParseError doc) = show doc

instance Exception ParseError

-- TODO: Support parsing from file for better error messages

-- | Parse an expression from `Text` containing a Dhall program program
exprFromText :: Text -> Either ParseError (Expr Src Path)
exprFromText text = case result of
    Success r       -> Right r
    Failure errInfo -> Left (ParseError (Text.Trifecta._errDoc errInfo))
  where
    string = Data.Text.Lazy.unpack text

    parser = do
        Text.Parser.Token.whiteSpace
        r <- unParser exprA
        Text.Parser.Combinators.eof
        return r

    result = Text.Trifecta.parseString parser  mempty string