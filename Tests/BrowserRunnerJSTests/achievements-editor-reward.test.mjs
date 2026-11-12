// Unit tests for the Reward control's rules in
// Public/achievements-editor-core.js (docs/achievement-rewards.md, S2): an
// individual row may grant a wardrobe item, every other row keeps its scope's
// own reward, and the table names the item a row grants.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const Core = require('../../Public/achievements-editor-core.js');

const ctx = {
  signalMeta: {}, sectionNames: {}, esc: (s) => String(s), dimLabel: (d) => d,
  itemLabel: (value) => ({ 'border.crossfade': 'Cross-fade' })[value] || value,
};

const form = (extra) => ({
  name: 'Painted a tile', scope: 'individual', match: 'all', conditions: [],
  rewardType: 'badge', rewardItem: 'border.crossfade', ...extra,
});

test('an individual row with a wardrobe reward sends the type and the item', () => {
  const built = Core.buildAchievement(form({ rewardType: 'wardrobe' }), null);
  assert.equal(built.ok, true);
  assert.equal(built.achievement.rewardType, 'wardrobe');
  assert.equal(built.achievement.rewardItem, 'border.crossfade');
});

test('a badge row sends no reward fields', () => {
  const built = Core.buildAchievement(form({}), null);
  assert.equal(built.achievement.rewardType, undefined);
  assert.equal(built.achievement.rewardItem, undefined);
});

test('a class goal or a record never sends a wardrobe reward', () => {
  for (const scope of ['classWide', 'record']) {
    const built = Core.buildAchievement(form({ scope, rewardType: 'wardrobe' }), null);
    assert.equal(built.achievement.rewardType, undefined, scope);
    assert.equal(built.achievement.rewardItem, undefined, scope);
  }
});

test('the summary names the item an individual row grants', () => {
  const row = { scope: 'individual', conditions: [], rewardType: 'wardrobe', rewardItem: 'border.crossfade' };
  assert.equal(Core.summary(row, ctx), 'always · Cross-fade');
  assert.equal(Core.grantsItem(row), true);
});

test('a badge row and a class goal read as before', () => {
  assert.equal(Core.summary({ scope: 'individual', conditions: [], rewardType: 'badge' }, ctx), 'always');
  const goal = { scope: 'classWide', conditions: [], classPercent: 80, points: 2, rewardType: 'points' };
  assert.equal(Core.grantsItem(goal), false);
  assert.equal(Core.summary(goal, ctx), 'always · by 80% of class · +2 pts');
});
