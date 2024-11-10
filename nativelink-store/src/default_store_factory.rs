// Copyright 2024 The NativeLink Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

use std::pin::Pin;
use std::sync::Arc;
use std::time::SystemTime;

use futures::stream::FuturesOrdered;
use futures::{Future, TryStreamExt};
use nativelink_config::stores::StoreConfig;
use nativelink_error::Error;
use nativelink_util::health_utils::HealthRegistryBuilder;
use nativelink_util::store_trait::{Store, StoreDriver};

use crate::completeness_checking_store::CompletenessCheckingStore;
use crate::compression_store::CompressionStore;
use crate::dedup_store::DedupStore;
use crate::existence_cache_store::ExistenceCacheStore;
use crate::fast_slow_store::FastSlowStore;
use crate::filesystem_store::FilesystemStore;
use crate::grpc_store::GrpcStore;
use crate::memory_store::MemoryStore;
use crate::noop_store::NoopStore;
use crate::redis_store::RedisStore;
use crate::ref_store::RefStore;
use crate::s3_store::S3Store;
use crate::shard_store::ShardStore;
use crate::size_partitioning_store::SizePartitioningStore;
use crate::store_manager::StoreManager;
use crate::verify_store::VerifyStore;

type FutureMaybeStore<'a> = Box<dyn Future<Output = Result<Store, Error>> + 'a>;

pub fn store_factory<'a>(
    config: &'a StoreConfig,
    store_manager: &'a Arc<StoreManager>,
    maybe_health_registry_builder: Option<&'a mut HealthRegistryBuilder>,
) -> Pin<FutureMaybeStore<'a>> {
    Box::pin(async move {
        let store: Arc<dyn StoreDriver> = match &config {
            StoreConfig::Memory { name: _, spec } => MemoryStore::new(spec),
            StoreConfig::S3 { name: _, spec } => S3Store::new(spec, SystemTime::now).await?,
            StoreConfig::Redis { name: _, spec } => RedisStore::new(spec.clone())?,
            StoreConfig::Verify { name: _, spec } => VerifyStore::new(
                spec,
                store_factory(&spec.backend, store_manager, None).await?,
            ),
            StoreConfig::Compression { name: _, spec } => CompressionStore::new(
                &spec.clone(),
                store_factory(&spec.backend, store_manager, None).await?,
            )?,
            StoreConfig::Dedup { name: _, spec } => DedupStore::new(
                spec,
                store_factory(&spec.index_store, store_manager, None).await?,
                store_factory(&spec.content_store, store_manager, None).await?,
            )?,
            StoreConfig::ExistenceCache { name: _, spec } => ExistenceCacheStore::new(
                spec,
                store_factory(&spec.backend, store_manager, None).await?,
            ),
            StoreConfig::CompletenessChecking { name: _, spec } => CompletenessCheckingStore::new(
                store_factory(&spec.backend, store_manager, None).await?,
                store_factory(&spec.cas_store, store_manager, None).await?,
            ),
            StoreConfig::FastSlow { name: _, spec } => FastSlowStore::new(
                spec,
                store_factory(&spec.fast, store_manager, None).await?,
                store_factory(&spec.slow, store_manager, None).await?,
            ),
            StoreConfig::Filesystem { name: _, spec } => <FilesystemStore>::new(spec).await?,
            StoreConfig::Ref { name: _, spec } => {
                RefStore::new(spec, Arc::downgrade(store_manager))
            }
            StoreConfig::SizePartitioning { name: _, spec } => SizePartitioningStore::new(
                spec,
                store_factory(&spec.lower_store, store_manager, None).await?,
                store_factory(&spec.upper_store, store_manager, None).await?,
            ),
            StoreConfig::Grpc { name: _, spec } => GrpcStore::new(spec).await?,
            StoreConfig::Noop { name: _, spec: _ } => NoopStore::new(),
            StoreConfig::Shard { name: _, spec } => {
                let stores = spec
                    .stores
                    .iter()
                    .map(|store_config| store_factory(&store_config.store, store_manager, None))
                    .collect::<FuturesOrdered<_>>()
                    .try_collect::<Vec<_>>()
                    .await?;
                ShardStore::new(spec, stores)?
            }
        };

        if let Some(health_registry_builder) = maybe_health_registry_builder {
            store.clone().register_health(health_registry_builder);
        }

        Ok(Store::new(store))
    })
}
