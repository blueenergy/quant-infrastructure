// MongoDB 初始化脚本
// 创建数据库和用户

// 切换到 admin 数据库
db = db.getSiblingDB('admin');

// 使用 root 用户认证
db.auth(
  process.env.MONGO_INITDB_ROOT_USERNAME,
  process.env.MONGO_INITDB_ROOT_PASSWORD
);

// 创建 finance 数据库
db = db.getSiblingDB('finance');

// 创建应用用户（读写权限）
db.createUser({
  user: 'quant_user',
  pwd: 'quant_password_changeme',
  roles: [
    {
      role: 'readWrite',
      db: 'finance'
    }
  ]
});

print('✅ Created database: finance');
print('✅ Created user: quant_user');

// 创建常用集合和索引
// ========================
// 分钟数据集合
// ========================
db.createCollection('minute_bars');
db.minute_bars.createIndex(
  { symbol: 1, datetime: 1 },
  { unique: true, background: true }
);
db.minute_bars.createIndex(
  { symbol: 1, trade_date: 1 },
  { background: true }
);
db.minute_bars.createIndex(
  { datetime: 1 },
  { 
    expireAfterSeconds: 7776000,  // 90 天后自动删除
    background: true 
  }
);
print('✅ Created collection: minute_bars with indexes');

// ========================
// 日线数据集合
// ========================
db.createCollection('volume_price');
db.volume_price.createIndex(
  { symbol: 1, trade_date: 1 },
  { unique: true, background: true }
);
db.volume_price.createIndex(
  { trade_date: 1 },
  { background: true }
);
print('✅ Created collection: volume_price with indexes');

// ========================
// 交易信号集合
// ========================
db.createCollection('trade_signals');
db.trade_signals.createIndex(
  { symbol: 1, timestamp: -1 },
  { background: true }
);
db.trade_signals.createIndex(
  { status: 1, timestamp: -1 },
  { background: true }
);
db.trade_signals.createIndex(
  { order_id: 1 },
  { unique: true, background: true }
);
print('✅ Created collection: trade_signals with indexes');

// ========================
// 回测交易记录集合
// ========================
db.createCollection('backtest_trades');
db.backtest_trades.createIndex(
  { symbol: 1, datetime: -1 },
  { background: true }
);
print('✅ Created collection: backtest_trades with indexes');

// ========================
// 策略状态集合
// ========================
db.createCollection('strategy_states');
db.strategy_states.createIndex(
  { symbol: 1, strategy_name: 1, user_id: 1 },
  { unique: true, background: true }
);
db.strategy_states.createIndex(
  { timestamp: -1 },
  { background: true }
);
print('✅ Created collection: strategy_states with indexes');

// ========================
// 持仓数据集合
// ========================
db.createCollection('positions');
db.positions.createIndex(
  { symbol: 1, timestamp: -1 },
  { background: true }
);
print('✅ Created collection: positions with indexes');

// ========================
// Worker 运行状态集合
// ========================
db.createCollection('runtime_status');
db.runtime_status.createIndex(
  { symbol: 1 },
  { unique: true, background: true }
);
db.runtime_status.createIndex(
  { status: 1, updated_at: -1 },
  { background: true }
);
print('✅ Created collection: runtime_status with indexes');

// ========================
// 自选股集合
// ========================
db.createCollection('watchlist_strategies');
db.watchlist_strategies.createIndex(
  { symbol: 1, strategy_key: 1, user_id: 1 },
  { unique: true, background: true }
);
db.watchlist_strategies.createIndex(
  { user_id: 1, active: 1 },
  { background: true }
);
print('✅ Created collection: watchlist_strategies with indexes');

print('');
print('='.repeat(60));
print('MongoDB initialization completed successfully!');
print('='.repeat(60));
print('');
print('Database: finance');
print('Application User: quant_user');
print('');
print('⚠️  IMPORTANT: Change the default password in production!');
print('');
