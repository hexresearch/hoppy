{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE CPP #-}

module Ergvein.Wallet.Main(
    frontend
  , mainWidgetWithCss
  ) where

import Reflex.Dom.Main (mainWidgetWithCss)

import Ergvein.Types.Storage
import Ergvein.Wallet.Monad
import Ergvein.Wallet.Page.Balances
import Ergvein.Wallet.Page.Initial
import Ergvein.Wallet.Page.Restore
import Sepulcas.Loading
import Sepulcas.Log
#ifdef TESTNET
import Sepulcas.Elements
import Ergvein.Wallet.Localize
import Ergvein.Wallet.Wrapper
#endif

frontend :: MonadFrontBase t m => m ()
frontend = do
  logWrite "Frontend started"
  loadingWidget
  logWriter . fst =<< getLogsTrigger
  logWrite "Entering initial page"
  spawnPreWorkers
  mainpageDispatcher

startPage :: MonadFront t m => m ()
startPage = do
  buildE <- getPostBuild
  storedE <- storeWalletNow "start-page" False buildE
  ps <- getPubStorage
  void $ nextWidget $ ffor storedE $ const Retractable {
      retractableNext = if _pubStorage'restoring ps
        then restorePage
        else balancesPage
    , retractablePrev = Nothing
    }

#ifdef TESTNET
mainpageDispatcher :: MonadFrontBase t m => m ()
mainpageDispatcher = void $ workflow testnetDisclaimer
  where
    testnetDisclaimer = Workflow $ wrapperSimple True $ do
      elClass "h4" "testnet-disclaimer-label" $ dynText =<< localized TestnetDisclaimerLabel
      elClass "p" "testnet-disclaimer-text" $ dynText =<< localized TestnetDisclaimerText
      closeE <- outlineButton TestnetDisclaimerClose
      pure ((), startWallet <$ closeE)
    startWallet = Workflow $ do
      void $ retractStack (initialPage OpenLastWalletOn) `liftAuth` (spawnWorkers >> retractStack startPage)
      pure ((), never)
#else
mainpageDispatcher :: MonadFrontBase t m => m ()
mainpageDispatcher = void $ retractStack (initialPage OpenLastWalletOn) `liftAuth` (spawnWorkers >> retractStack startPage)
#endif