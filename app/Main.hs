{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TupleSections #-}

module Main where

import           Control.Lens
import           Control.Monad
import           Data.Aeson                 as A
import           Data.Aeson.Lens
import           Data.Time
import           Development.Shake
import           Development.Shake.Classes
import           Development.Shake.Forward
import           Development.Shake.FilePath
import           GHC.Generics               (Generic)
import           Slick

import qualified Data.HashMap.Lazy          as HML
import qualified Data.Text                  as T
import Data.List (sortBy)
import qualified Data.Map                   as DM 
---Config-----------------------------------------------------------------------

siteMeta :: SiteMeta
siteMeta =
    SiteMeta { siteAuthor = "axiomsbane"
             , baseUrl = "https://axiomsbane.github.io"
             , siteTitle = "axiomsbane"
             , linkedInUser = Just "aditya-shidhaye-a48b771a6"
             , githubUser = Just "axiomsbane"
             }

outputFolder :: FilePath
outputFolder = "docs/"

tagsFolder :: FilePath
tagsFolder = "tags/"

--Data models-------------------------------------------------------------------

withSiteMeta :: Value -> Value
withSiteMeta (Object obj) = Object $ HML.union obj siteMetaObj
  where
    Object siteMetaObj = toJSON siteMeta
withSiteMeta _ = error "only add site meta to objects"

data SiteMeta =
    SiteMeta { siteAuthor    :: String
             , baseUrl       :: String -- e.g. https://example.ca
             , siteTitle     :: String
             , linkedInUser :: Maybe String -- Without @
             , githubUser    :: Maybe String
             }
    deriving (Generic, Eq, Ord, Show, ToJSON)

-- | Data for the index page
newtype PostsInfo = PostsInfo
    { posts :: [Post] 
    } deriving (Generic, Show, FromJSON, ToJSON)

data TaggedBasedPostsInfo = TaggedBasedPostsInfo
    { posts :: [Post]
    , mainTag :: Tag
    } deriving (Generic, Show, FromJSON, ToJSON)

data Bio = Bio
    { email :: String
    , location :: String
    , content :: String
    }
    deriving (Generic, Eq, Show, FromJSON, ToJSON, Binary)

type Tag = String

-- | Data for a blog post
data Post =
    Post { title       :: String
         , author      :: String
         , content     :: String
         , url         :: String
         , date        :: String
         , tags        :: [Tag]
         , description :: String
         , image       :: Maybe String
         }
    deriving (Generic, Eq, Ord, Show, FromJSON, ToJSON, Binary)

data IndexInfo = 
    IndexInfo { title :: String
              , content  :: String 
              }
    deriving (Generic, Eq, Ord, Show, FromJSON, ToJSON, Binary)

data AtomData =
  AtomData { title        :: String
           , domain       :: String
           , author       :: String
           , posts        :: [Post]
           , currentTime  :: String
           , atomUrl      :: String } deriving (Generic, ToJSON, Eq, Ord, Show)

-- | given a list of posts this will build a table of contents
buildIndex :: Action ()
buildIndex = do
  [indexInfoPath] <- getDirectoryFiles "." ["site/index.md"]
  indexInfoLol <- buildIndexInformation indexInfoPath
  indexTemplate <- compileTemplate' "site/templates/index.html"
  let indexHtml = T.unpack $ substitute indexTemplate $ withSiteMeta $ toJSON indexInfoLol
  writeFile' (outputFolder </> "index.html") indexHtml

buildIndexInformation :: FilePath -> Action IndexInfo
buildIndexInformation srcPath = cacheAction ("build" :: T.Text, srcPath) $ do 
  liftIO . putStrLn $ "Building Index page: " <> srcPath
  indexBody <- readFile' srcPath
  indexBodyHtml <- markdownToHTML . T.pack $ indexBody 
  convert indexBodyHtml

-- | Find and build all posts
buildPosts :: Action [Post]
buildPosts = do
  pPaths <- getDirectoryFiles "." ["site/posts//*.md"]
  forP pPaths buildPost

-- | Load a post, process metadata, write it to output, then return the post object
-- Detects changes to either post content or template
buildPost :: FilePath -> Action Post
buildPost srcPath = cacheAction ("build" :: T.Text, srcPath) $ do
  liftIO . putStrLn $ "Rebuilding post: " <> srcPath
  postContent <- readFile' srcPath
  -- load post content and metadata as JSON blob
  postData <- markdownToHTML . T.pack $ postContent
  let postUrl = T.pack . dropDirectory1 $ srcPath -<.> "html"
      withPostUrl = _Object . at "url" ?~ String postUrl
  -- Add additional metadata we've been able to compute
  let fullPostData = withSiteMeta . withPostUrl $ postData
  template <- compileTemplate' "site/templates/post.html"
  writeFile' (outputFolder </> T.unpack postUrl) . T.unpack $ substitute template fullPostData
  convert fullPostData

-- | Copy all static files from the listed folders to their destination
copyStaticFiles :: Action ()
copyStaticFiles = do
    filepaths <- getDirectoryFiles "./site/" ["images//*", "css//*", "js//*"]
    void $ forP filepaths $ \filepath ->
        copyFileChanged ("site" </> filepath) (outputFolder </> filepath)

formatDate :: String -> String
formatDate humanDate = toIsoDate parsedTime
  where
    parsedTime =
      parseTimeOrError True defaultTimeLocale "%b %e, %Y" humanDate :: UTCTime

rfc3339 :: Maybe String
rfc3339 = Just "%H:%M:SZ"

toIsoDate :: UTCTime -> String
toIsoDate = formatTime defaultTimeLocale (iso8601DateFormat rfc3339)

buildFeed :: [Post] -> Action ()
buildFeed posts = do
  now <- liftIO getCurrentTime
  let atomData =
        AtomData
          { title = siteTitle siteMeta
          , domain = baseUrl siteMeta
          , author = siteAuthor siteMeta
          , posts = mkAtomPost <$> posts
          , currentTime = toIsoDate now
          , atomUrl = "/atom.xml"
          }
  atomTempl <- compileTemplate' "site/templates/atom.xml"
  writeFile' (outputFolder </> "atom.xml") . T.unpack $ substitute atomTempl (toJSON atomData)
    where
      mkAtomPost :: Post -> Post
      mkAtomPost p = p { date = formatDate $ date p }


buildTableOfContents :: [Post] -> Action ()
buildTableOfContents posts' = do
  postsT <- compileTemplate' "site/templates/posts.html"
  let postsInfo = PostsInfo{posts = sortBy (\x y -> compare (date y) (date x)) posts'}
      postsHTML = T.unpack $ substitute postsT (withSiteMeta $ toJSON postsInfo)
  writeFile' (outputFolder </> "posts.html") postsHTML

tagPostListBuilder :: [Post] -> [(Tag, Post)]
tagPostListBuilder = concatMap (\p -> map (, p) (tags p))

tagPostMapBuilder :: [(Tag, Post)] -> DM.Map Tag [Post]
tagPostMapBuilder = foldr (\curPair curMap -> DM.adjust (snd curPair:) (fst curPair) curMap) DM.empty 

buildTagGrouping :: [Post] -> Action [()]
buildTagGrouping posts' = do 
  let tagPostList = DM.toList $ tagPostMapBuilder $ tagPostListBuilder posts'
      taggedBasedPosts = map (\(tg, pstList) -> TaggedBasedPostsInfo{mainTag = tg, posts=pstList}) tagPostList
  forP taggedBasedPosts buildTagBasedPage

buildTagBasedPage :: TaggedBasedPostsInfo -> Action ()
buildTagBasedPage tagguInfo = do 
  tagBasedPostsT <- compileTemplate' "site/templates/tagBasedPostList.html"
  -- let sortedTagBasedPosts = tagguInfo{posts = sortBy (\x y -> compare (date y) (date x)) (posts tagguInfo)} 
  --     tagBasedHTML = T.unpack $ substitute tagBasedPostsT (withSiteMeta $ toJSON sortedTagBasedPosts)
  let tagBasedHTML = T.unpack $ substitute tagBasedPostsT (withSiteMeta $ toJSON tagguInfo)
  writeFile' (outputFolder </> tagsFolder </> (mainTag tagguInfo ++ ".html")) tagBasedHTML


-- | Specific build rules for the Shake system
--   defines workflow to build the website
buildRules :: Action ()
buildRules = do
  allPosts <- buildPosts
  buildIndex
  buildFeed allPosts
  buildTableOfContents allPosts
  buildTagGrouping allPosts
  copyStaticFiles

main :: IO ()
main = do
  let shOpts = shakeOptions { shakeVerbosity = Chatty, shakeLintInside = ["\\"]}
  shakeArgsForward shOpts buildRules
